#!/usr/bin/env bash
# shellcheck shell=bash
#
# gitleaks.sh — deterministic secret-scan gate for /auto (decisions.md §5,
# architecture §4 / §6 A10).
#
# Two responsibilities:
#   1. gitleaks_assert_present — HARD preflight assertion (A10). gitleaks MUST be
#      installed; if absent the run ABORTS (EX_PREFLIGHT_GITLEAKS=68) rather than
#      silently shipping unscanned commits. This closes the "WARN-and-skip" gap
#      the critique flagged.
#   2. gitleaks_scan_staged — the commit-gate scan: `gitleaks protect --staged
#      --redact` against the staged tree, using the shipped config at
#      templates/.gitleaks.toml unless the target repo supplies its own. A hit
#      REJECTS the commit (the engine must fix-forward).
#
# This deterministic gate is COMPLEMENTARY to the read-only review-secrets-leaks
# subagent (which does manual review + an independent gitleaks pass at a
# different granularity); they are deliberately two scans, not one (critique).
#
# `--redact` ensures any matched secret is never echoed into logs/output.
#
# Sourced (never executed). Depends on constants.sh + log.sh.
#
set -euo pipefail

_AUTO_GL_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -z "${AUTO_CONSTANTS_SOURCED:-}" ]]; then
  # shellcheck source=constants.sh
  source "${_AUTO_GL_LIBDIR}/constants.sh"
fi
if [[ -z "${AUTO_LOG_SOURCED:-}" ]]; then
  # shellcheck source=log.sh
  source "${_AUTO_GL_LIBDIR}/log.sh"
fi

if [[ -n "${AUTO_GITLEAKS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly AUTO_GITLEAKS_SOURCED=1

# Shipped baseline config. lib/ -> ../templates/.gitleaks.toml (legacy plugin layout, no longer used:
# plugins/auto/templates/.gitleaks.toml). The installer also drops a copy at the
# target repo root; a repo-local config there takes precedence.
_auto_gl_root="$(cd "${_AUTO_GL_LIBDIR}/.." && pwd)"
readonly AUTO_GITLEAKS_CONFIG="${_auto_gl_root}/templates/.gitleaks.toml"

# =========================================================================== #
# 1. PRESENCE ASSERTION (preflight A10) — HARD ABORT if gitleaks is missing.
# =========================================================================== #

# gitleaks_present
#   Predicate: true (0) iff a gitleaks binary is on PATH. No logging (callers
#   decide whether absence is fatal).
gitleaks_present() {
  command -v gitleaks >/dev/null 2>&1
}

# gitleaks_assert_present
#   HARD assertion for preflight A10. Logs ERROR-with-cause and returns
#   EX_PREFLIGHT_GITLEAKS (68) if gitleaks is absent; prints the resolved version
#   and returns 0 if present. The driver maps 68 to a halt-for-human abort.
gitleaks_assert_present() {
  if ! gitleaks_present; then
    log_error "gitleaks.assert" "gitleaks-not-installed" \
      "commit secret-scan gate cannot run; install gitleaks (e.g. brew install gitleaks) and re-run"
    return "$EX_PREFLIGHT_GITLEAKS"
  fi
  local ver
  ver="$(gitleaks version 2>/dev/null | head -1 || true)"
  log_info "gitleaks.assert" "present version=${ver:-unknown}"
  printf '%s\n' "${ver:-unknown}"
}

# =========================================================================== #
# 2. CONFIG RESOLUTION — prefer a repo-local config, else the shipped baseline.
# =========================================================================== #

# gitleaks_config_path [worktree-path]
#   Print the gitleaks config path to use:
#     - a repo-local .gitleaks.toml at the (worktree) root if present, else
#     - the shipped templates/.gitleaks.toml baseline, else
#     - empty (gitleaks then uses its built-in default rule set).
gitleaks_config_path() {
  local root="${1:-${AUTO_ROOT}}"
  if [[ -f "${root}/.gitleaks.toml" ]]; then
    printf '%s\n' "${root}/.gitleaks.toml"; return 0
  fi
  if [[ -f "$AUTO_GITLEAKS_CONFIG" ]]; then
    printf '%s\n' "$AUTO_GITLEAKS_CONFIG"; return 0
  fi
  printf '%s\n' ""   # let gitleaks fall back to its embedded defaults.
}

# =========================================================================== #
# 3. STAGED SCAN — the commit gate (decisions.md §5, architecture §4).
#    `gitleaks protect --staged --redact`. A hit => reject the commit.
# =========================================================================== #

# gitleaks_scan_staged [worktree-path]
#   Run gitleaks against the STAGED changes in the given worktree (default cwd /
#   AUTO_ROOT). Returns:
#     0  -> clean (no secrets in the staged diff).
#     EX_CHECK_FAIL (2) -> secrets found; commit MUST be rejected.
#     EX_PREFLIGHT_GITLEAKS (68) -> gitleaks not installed (fail closed; never
#        silently pass an unscanned commit — this should already have aborted at
#        preflight A10, but the gate re-checks defensively).
#   Output is --redact'd so a matched secret is never printed. The redacted
#   gitleaks report is forwarded to stderr for operator context.
gitleaks_scan_staged() {
  local wt="${1:-${AUTO_ROOT}}"

  if ! gitleaks_present; then
    log_error "gitleaks.scan" "gitleaks-not-installed" "refusing to commit unscanned (worktree=${wt})"
    return "$EX_PREFLIGHT_GITLEAKS"
  fi

  local cfg; cfg="$(gitleaks_config_path "$wt")"
  local -a args=(protect --staged --redact --no-banner)
  [[ -n "$cfg" ]] && args+=(--config "$cfg")
  # `--source` scopes the scan to the worktree so a multi-worktree run scans the
  # right staged index.
  args+=(--source "$wt")

  local out rc
  set +e
  out="$(gitleaks "${args[@]}" 2>&1)"
  rc=$?
  set -e

  if (( rc == 0 )); then
    log_debug "gitleaks.scan" "clean worktree=${wt} config=${cfg:-builtin}"
    return 0
  fi

  # gitleaks exits 1 when leaks are found. Anything else is a tool/usage error;
  # treat BOTH as a hard fail (fail closed) so a misconfigured scan never lets a
  # commit through unverified.
  log_error "gitleaks.scan" "secrets-detected-or-scan-error" \
    "worktree=${wt} rc=${rc} (report redacted) -- ${out:0:240}"
  return "$EX_CHECK_FAIL"
}
