#!/usr/bin/env bash
# shellcheck shell=bash
#
# build-check.sh — the FAST build/test gate (buildable-per-commit enforcement).
#
# Auto-detects the project's ecosystem and runs a FAST, deterministic build/test
# command against the working tree. Invoked by commit-gate.sh before finalizing
# every commit (architecture §4 item 4 / decisions.md §5 "buildable-per-commit"),
# so a subagent can never commit a broken intermediate state that only the
# PR-level CI would catch. The full CI on the PR remains the authoritative gate;
# this is the cheap early tripwire.
#
# Detection order (first match wins UNLESS auto.config.json overrides):
#   1. auto.config.json   .github/auto/auto.config.json -> .buildCheck.commands[]
#   2. Node      package.json with a "build" and/or "test" script  -> npm run ...
#   3. Python    pyproject.toml / setup.cfg / pytest.ini / tox.ini -> pytest -x -q
#   4. Go        go.mod                                            -> go build ./...
#   5. Make      Makefile with a `check` target                    -> make check
#   6. none detectable -> no-op WITH WARN (decisions.md: only no-op-with-WARN here).
#
# Config override (.github/auto/auto.config.json):
#   {
#     "buildCheck": {
#       "enabled": true,                         // false => skip with WARN
#       "commands": ["npm run lint", "npm test"] // run in order; any non-zero fails
#     }
#   }
# When .buildCheck.commands is a non-empty array it FULLY REPLACES auto-detection.
#
# Usage:
#   build-check.sh [--dir <path>]
#     --dir <path>   directory to run the gate in (default: AUTO_ROOT, else cwd).
#
# Exit codes (decisions.md §6):
#   0  build/test gate PASSED, or no gate detectable (no-op WARN), or disabled.
#   2  build/test gate FAILED (check fail).  -> commit-gate.sh rejects the commit.
#   1  generic/internal error.
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Source shared libs (lib/ is a sibling of bin/).
# --------------------------------------------------------------------------- #
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_SELF_DIR}/../lib/constants.sh"
# shellcheck source=../lib/log.sh
source "${_SELF_DIR}/../lib/log.sh"

export AUTO_PHASE="${AUTO_PHASE:-build-check}"

# Print the leading header comment block (top-of-file usage) and exit 0.
print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
WORK_DIR="${AUTO_ROOT:-$(pwd)}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) WORK_DIR="${2:?--dir requires a path}"; shift 2 ;;
    -h|--help) print_help ;;
    *)
      log_error "build_check_args" "unknown-arg" "unknown argument: $1"
      exit "$EX_ERR" ;;
  esac
done

if [[ ! -d "$WORK_DIR" ]]; then
  log_error "build_check_dir" "missing-dir" "work dir does not exist: $WORK_DIR"
  exit "$EX_ERR"
fi

# --------------------------------------------------------------------------- #
# run_cmd <description> <command-string>
#   Runs a command string via `bash -c` in WORK_DIR. Returns the command's exit.
#   Logged at INFO (start) and ERROR (on failure, with the exit code as cause).
# --------------------------------------------------------------------------- #
run_cmd() {
  local desc="$1" cmd="$2" rc=0
  log_info "build_check_run" "${desc}: ${cmd}"
  ( cd "$WORK_DIR" && bash -c "$cmd" ) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log_error "build_check_step_fail" "exit-${rc}" "${desc} failed: ${cmd}"
  fi
  return "$rc"
}

# --------------------------------------------------------------------------- #
# 1. Config-driven override (auto.config.json .buildCheck).
#    AUTO_CONFIG_PATH is repo-relative; resolve it under WORK_DIR.
# --------------------------------------------------------------------------- #
CONFIG_FILE="${WORK_DIR}/${AUTO_CONFIG_PATH}"
if [[ -f "$CONFIG_FILE" ]]; then
  # .buildCheck.enabled == false -> explicit skip. NOTE: do NOT use `// empty`,
  # jq's alternative operator treats `false` as falsy and would discard it; read
  # the raw value and compare directly.
  config_enabled="$(jq -r 'if has("buildCheck") and (.buildCheck|has("enabled")) then (.buildCheck.enabled|tostring) else "" end' "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ "$config_enabled" == "false" ]]; then
    log_info "build_check_disabled" "buildCheck.enabled=false in ${AUTO_CONFIG_PATH}; skipping (WARN)"
    log_error "build_check_skip" "config-disabled" \
      "WARN: build/test gate disabled by config; per-commit buildability NOT verified"
    exit "$EX_OK"
  fi

  # .buildCheck.commands[] (non-empty) -> fully replaces auto-detection.
  # bash 3.2-compatible array read (no mapfile/readarray); newline-delimited.
  CFG_CMDS=()
  while IFS= read -r _cmd_line; do
    [[ -n "$_cmd_line" ]] && CFG_CMDS+=("$_cmd_line")
  done < <(jq -r '.buildCheck.commands[]? // empty' "$CONFIG_FILE" 2>/dev/null || true)
  if [[ "${#CFG_CMDS[@]}" -gt 0 ]]; then
    log_info "build_check_config" "running ${#CFG_CMDS[@]} configured command(s) from ${AUTO_CONFIG_PATH}"
    for c in "${CFG_CMDS[@]}"; do
      [[ -n "$c" ]] || continue
      run_cmd "config-command" "$c" || exit "$EX_CHECK_FAIL"
    done
    log_info "build_check_pass" "all configured build/test commands passed"
    exit "$EX_OK"
  fi
fi

# --------------------------------------------------------------------------- #
# 2. Auto-detection (first matching ecosystem wins).
# --------------------------------------------------------------------------- #

# --- Node / npm -----------------------------------------------------------
if [[ -f "${WORK_DIR}/package.json" ]]; then
  log_info "build_check_detect" "ecosystem=node (package.json)"
  has_script() {
    jq -e --arg s "$1" '.scripts[$s] // empty' "${WORK_DIR}/package.json" >/dev/null 2>&1
  }
  ran_any=0
  # Prefer a lockfile-aware install only if node_modules is absent AND a lockfile
  # exists — but keep the gate FAST: skip install, assume deps present (CI installs).
  if has_script "build"; then
    run_cmd "npm-build" "npm run build --if-present" || exit "$EX_CHECK_FAIL"
    ran_any=1
  fi
  if has_script "test"; then
    # CI=true makes most JS test runners non-interactive / single-run.
    run_cmd "npm-test" "CI=true npm test --if-present" || exit "$EX_CHECK_FAIL"
    ran_any=1
  fi
  if [[ "$ran_any" -eq 1 ]]; then
    log_info "build_check_pass" "node build/test gate passed"
    exit "$EX_OK"
  fi
  log_info "build_check_node_noscripts" "package.json has no build/test script; trying other detectors"
fi

# --- Python / pytest ------------------------------------------------------
if [[ -f "${WORK_DIR}/pyproject.toml" || -f "${WORK_DIR}/setup.cfg" \
      || -f "${WORK_DIR}/pytest.ini" || -f "${WORK_DIR}/tox.ini" \
      || -f "${WORK_DIR}/setup.py" ]]; then
  log_info "build_check_detect" "ecosystem=python"
  if ( cd "$WORK_DIR" && python3 -c 'import pytest' >/dev/null 2>&1 ); then
    # -x stop on first failure, -q quiet: FAST gate.
    run_cmd "pytest" "python3 -m pytest -x -q" || exit "$EX_CHECK_FAIL"
    log_info "build_check_pass" "python pytest gate passed"
    exit "$EX_OK"
  fi
  log_info "build_check_py_nopytest" "pytest not importable; trying other detectors"
fi

# --- Go -------------------------------------------------------------------
if [[ -f "${WORK_DIR}/go.mod" ]]; then
  log_info "build_check_detect" "ecosystem=go (go.mod)"
  if command -v go >/dev/null 2>&1; then
    run_cmd "go-build" "go build ./..." || exit "$EX_CHECK_FAIL"
    # go vet is fast and catches a class of broken-build issues; non-fatal extras
    # are intentionally NOT added here to keep the gate fast/deterministic.
    log_info "build_check_pass" "go build gate passed"
    exit "$EX_OK"
  fi
  log_info "build_check_go_nogo" "go toolchain not found; trying other detectors"
fi

# --- Make (check target) --------------------------------------------------
if [[ -f "${WORK_DIR}/Makefile" || -f "${WORK_DIR}/makefile" ]]; then
  MKFILE="${WORK_DIR}/Makefile"; [[ -f "$MKFILE" ]] || MKFILE="${WORK_DIR}/makefile"
  if command -v make >/dev/null 2>&1 \
     && grep -qE '^check[[:space:]]*:' "$MKFILE" 2>/dev/null; then
    log_info "build_check_detect" "ecosystem=make (check target)"
    run_cmd "make-check" "make check" || exit "$EX_CHECK_FAIL"
    log_info "build_check_pass" "make check gate passed"
    exit "$EX_OK"
  fi
fi

# --------------------------------------------------------------------------- #
# 3. Nothing detectable -> no-op WITH WARN (the ONLY sanctioned no-op path).
# --------------------------------------------------------------------------- #
log_info "build_check_none" "no build/test gate detected"
log_error "build_check_skip" "no-gate-detected" \
  "WARN: no build/test gate detectable (no auto.config.json buildCheck, package.json, pyproject/pytest, go.mod, or Makefile:check); per-commit buildability NOT verified"
exit "$EX_OK"
