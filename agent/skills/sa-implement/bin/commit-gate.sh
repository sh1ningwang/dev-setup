#!/usr/bin/env bash
# shellcheck shell=bash
#
# commit-gate.sh — the mandatory gate every /auto commit passes through.
#
# The engine NEVER calls raw `git commit`; it commits through this gate so the
# four hard rules are ENFORCED, not advisory (architecture §4 / decisions.md §5):
#
#   1. REJECT any `Co-Authored-By:` line in the message  (HC6 / user rule: never).
#   2. REJECT a non-conventional subject (`type(scope)!: subject`).
#   3. gitleaks HARD on the staged tree (`gitleaks protect --staged --redact`).
#      gitleaks ABSENT is a HARD FAILURE here, not a WARN (decisions.md / critique
#      #8): a host without gitleaks must not ship unscanned commits. Preflight A10
#      also asserts presence, this is defense-in-depth.
#   4. RUN build-check.sh (buildable-per-commit). Non-zero rejects the commit.
#
# Any failure exits NON-ZERO and the caller must NOT proceed to `git commit`.
# This script does NOT itself create the commit — it gates a staged tree + a
# prepared message. The caller commits only on exit 0.
#
# Usage (two shapes, pick one):
#   commit-gate.sh --message-file <path>   # message already in a file
#   commit-gate.sh --message "<text>"      # message inline (written to a temp file)
# Optional:
#   --dir <path>        repo/worktree dir to gate (default: AUTO_ROOT, else cwd).
#   --skip-build        skip step 4 (build-check). Reserved for callers that run
#                       build-check separately; logged loudly. NEVER skips 1-3.
#
# Exit codes (decisions.md §6):
#   0  all gates passed; caller may commit.
#   1  a gate REJECTED the commit (co-author / non-conventional / gitleaks / build).
#      (Generic reject code; the cause is logged + printed for the engine to read.)
#   2  build-check reported a check failure (propagated distinctly when isolatable).
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_SELF_DIR}/../lib/constants.sh"
# shellcheck source=../lib/log.sh
source "${_SELF_DIR}/../lib/log.sh"

export AUTO_PHASE="${AUTO_PHASE:-commit-gate}"

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
MSG_FILE=""
MSG_INLINE=""
WORK_DIR="${AUTO_ROOT:-$(pwd)}"
SKIP_BUILD=0
_TMP_MSG=""

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below.
cleanup() { [[ -n "$_TMP_MSG" && -f "$_TMP_MSG" ]] && rm -f "$_TMP_MSG"; return 0; }
trap cleanup EXIT

# Print the leading header comment block (top-of-file usage) and exit 0.
print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message-file) MSG_FILE="${2:?--message-file requires a path}"; shift 2 ;;
    --message)      MSG_INLINE="${2?--message requires text}"; shift 2 ;;
    --dir)          WORK_DIR="${2:?--dir requires a path}"; shift 2 ;;
    --skip-build)   SKIP_BUILD=1; shift ;;
    -h|--help) print_help ;;
    *)
      log_error "commit_gate_args" "unknown-arg" "unknown argument: $1"
      exit "$EX_ERR" ;;
  esac
done

if [[ -z "$MSG_FILE" && -z "$MSG_INLINE" ]]; then
  log_error "commit_gate_args" "no-message" "one of --message-file / --message is required"
  exit "$EX_ERR"
fi
if [[ -n "$MSG_FILE" && -n "$MSG_INLINE" ]]; then
  log_error "commit_gate_args" "ambiguous-message" "pass exactly one of --message-file / --message"
  exit "$EX_ERR"
fi
if [[ -n "$MSG_INLINE" ]]; then
  _TMP_MSG="$(mktemp -t auto-commit-msg.XXXXXX)"
  printf '%s\n' "$MSG_INLINE" > "$_TMP_MSG"
  MSG_FILE="$_TMP_MSG"
fi
if [[ ! -f "$MSG_FILE" ]]; then
  log_error "commit_gate_args" "missing-message-file" "message file not found: $MSG_FILE"
  exit "$EX_ERR"
fi
if [[ ! -d "$WORK_DIR" ]]; then
  log_error "commit_gate_dir" "missing-dir" "work dir does not exist: $WORK_DIR"
  exit "$EX_ERR"
fi

log_info "commit_gate_start" "gating commit in ${WORK_DIR}"

# --------------------------------------------------------------------------- #
# GATE 1 — reject Co-Authored-By (case-insensitive, anywhere in the message).
#          decisions.md §5 / HC6: NO Co-Authored-By lines, ever.
# --------------------------------------------------------------------------- #
if grep -qiE '^[[:space:]]*Co-Authored-By:' "$MSG_FILE"; then
  log_error "commit_gate_coauthor" "co-authored-by" \
    "REJECT: commit message contains a Co-Authored-By line (forbidden)"
  echo "[commit-gate] REJECT: Co-Authored-By line present (forbidden by project rule)" >&2
  exit "$EX_ERR"
fi
log_debug "commit_gate_coauthor_ok" "no Co-Authored-By line"

# --------------------------------------------------------------------------- #
# GATE 2 — conventional subject on the FIRST non-empty, non-comment line.
#   Format: type(scope)!: subject   (scope optional; '!' optional breaking marker).
#   Accepted types = the Conventional Commits standard set (superset of the branch
#   <type> tokens in AUTO_BRANCH_TYPES; commit type vocabulary is broader).
# --------------------------------------------------------------------------- #
SUBJECT="$(grep -vE '^[[:space:]]*#' "$MSG_FILE" | grep -vE '^[[:space:]]*$' | head -1 || true)"
if [[ -z "$SUBJECT" ]]; then
  log_error "commit_gate_subject" "empty-subject" "REJECT: empty commit subject"
  echo "[commit-gate] REJECT: empty commit subject" >&2
  exit "$EX_ERR"
fi
# type(scope)!: subject  — types per Conventional Commits.
CONV_RE='^(feat|fix|chore|spike|docs|test|perf|refactor|build|ci|style|revert)(\([a-z0-9._\/-]+\))?!?: .+'
if ! printf '%s' "$SUBJECT" | grep -Eq "$CONV_RE"; then
  log_error "commit_gate_subject" "non-conventional" \
    "REJECT: non-conventional subject: ${SUBJECT}"
  echo "[commit-gate] REJECT: subject not conventional (want 'type(scope): subject'): ${SUBJECT}" >&2
  exit "$EX_ERR"
fi
# Subject length advisory (<= 72 chars per conventions); WARN only, never block.
SUBJECT_LEN="${#SUBJECT}"
if [[ "$SUBJECT_LEN" -gt 72 ]]; then
  log_info "commit_gate_subject_long" "WARN: subject is ${SUBJECT_LEN} chars (>72): ${SUBJECT}"
fi
log_debug "commit_gate_subject_ok" "conventional subject: ${SUBJECT}"

# --------------------------------------------------------------------------- #
# GATE 3 — gitleaks HARD on the staged tree. Absence is a HARD failure.
#   `gitleaks protect --staged` scans staged changes; --redact hides secret values
#   from logs. Non-zero exit => a finding => REJECT.
# --------------------------------------------------------------------------- #
if ! command -v gitleaks >/dev/null 2>&1; then
  log_error "commit_gate_gitleaks" "gitleaks-absent" \
    "REJECT: gitleaks not installed; refusing to commit unscanned changes (preflight A10 should have caught this)"
  echo "[commit-gate] REJECT: gitleaks not installed (hard requirement; cannot scan for secrets)" >&2
  exit "$EX_ERR"
fi

GITLEAKS_RC=0
( cd "$WORK_DIR" && gitleaks protect --staged --redact ) >&2 || GITLEAKS_RC=$?
if [[ "$GITLEAKS_RC" -ne 0 ]]; then
  log_error "commit_gate_gitleaks" "secret-found" \
    "REJECT: gitleaks found secrets in staged changes (exit ${GITLEAKS_RC})"
  echo "[commit-gate] REJECT: gitleaks found secrets in staged changes" >&2
  exit "$EX_ERR"
fi
log_debug "commit_gate_gitleaks_ok" "gitleaks clean"

# --------------------------------------------------------------------------- #
# GATE 4 — build-check.sh (buildable-per-commit). Exit 2 => check fail => reject.
# --------------------------------------------------------------------------- #
if [[ "$SKIP_BUILD" -eq 1 ]]; then
  log_info "commit_gate_build_skip" "WARN: --skip-build set; per-commit buildability NOT verified here"
else
  BUILD_RC=0
  AUTO_PHASE="build-check" "${_SELF_DIR}/build-check.sh" --dir "$WORK_DIR" || BUILD_RC=$?
  if [[ "$BUILD_RC" -eq "$EX_CHECK_FAIL" ]]; then
    log_error "commit_gate_build" "build-fail" "REJECT: build-check failed (staged tree not buildable)"
    echo "[commit-gate] REJECT: build-check failed; fix-forward before committing" >&2
    exit "$EX_CHECK_FAIL"
  elif [[ "$BUILD_RC" -ne 0 ]]; then
    log_error "commit_gate_build" "build-error" "REJECT: build-check errored (exit ${BUILD_RC})"
    echo "[commit-gate] REJECT: build-check errored (exit ${BUILD_RC})" >&2
    exit "$EX_ERR"
  fi
fi

log_info "commit_gate_ok" "all commit gates passed"
echo "[commit-gate] OK"
exit "$EX_OK"
