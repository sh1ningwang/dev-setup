#!/usr/bin/env bash
# shellcheck shell=bash
#
# log.sh — structured logging for /auto. Pure bash (no jq dependency for writes).
#
# Every line goes to TWO sinks:
#   1. stderr  — human-readable, level-prefixed, ISO-8601 UTC timestamp.
#   2. NDJSON  — appended to the per-day journal at the path from constants.sh
#                (fields: ts, run, lvl, evt, issue, phase, cause). Disposable,
#                never committed (decisions.md §5).
#
# Levels (decisions.md §5):
#   log_info   INFO  — lifecycle events.
#   log_debug  DEBUG — detailed flow; emitted ONLY when AUTO_VERBOSE=1.
#   log_error  ERROR — failures, always carry a cause.
#
# Usage:
#   log_info  <evt> [msg...]                       # evt is a short machine token.
#   log_debug <evt> [msg...]
#   log_error <evt> <cause> [msg...]               # cause is required for ERROR.
#
# Context fields (issue/phase/run) are read from the environment so callers don't
# have to thread them through every call:
#   AUTO_RUN_ID   — current run id          (default "-")
#   AUTO_ISSUE    — current issue number    (default "-")
#   AUTO_PHASE    — current pipeline phase  (default "-")
#
set -euo pipefail

# Depends on constants.sh for AUTO_LOG_DIR / AUTO_LOG_PATH_PATTERN / AUTO_VERBOSE.
# Source it defensively so log.sh works even if sourced first.
if [[ -z "${AUTO_CONSTANTS_SOURCED:-}" ]]; then
  # shellcheck source=constants.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/constants.sh"
fi

if [[ -n "${AUTO_LOG_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly AUTO_LOG_SOURCED=1

# --------------------------------------------------------------------------- #
# Internal: ISO-8601 UTC timestamp with second precision.
# --------------------------------------------------------------------------- #
_auto_log_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --------------------------------------------------------------------------- #
# Internal: today's NDJSON journal path. Creates the log dir on demand.
# --------------------------------------------------------------------------- #
_auto_log_path() {
  local day
  day="$(date -u +%Y-%m-%d)"
  printf "${AUTO_LOG_PATH_PATTERN}" "$day"
}

# --------------------------------------------------------------------------- #
# Internal: JSON-escape a string for embedding in an NDJSON value (pure bash).
# Escapes backslash, double-quote, and control chars (newline/tab/CR).
# --------------------------------------------------------------------------- #
_auto_json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"     # backslash first
  s="${s//\"/\\\"}"     # double quote
  s="${s//$'\n'/\\n}"   # newline
  s="${s//$'\r'/\\r}"   # carriage return
  s="${s//$'\t'/\\t}"   # tab
  printf '%s' "$s"
}

# --------------------------------------------------------------------------- #
# Internal: emit one log line to stderr + NDJSON.
#   $1 level (INFO|DEBUG|ERROR)  $2 evt  $3 cause (may be empty)  $4.. msg
# --------------------------------------------------------------------------- #
_auto_log_emit() {
  local lvl="$1" evt="$2" cause="${3-}"; shift 3 || true
  local msg="$*"
  local ts run issue phase
  ts="$(_auto_log_ts)"
  run="${AUTO_RUN_ID:--}"
  issue="${AUTO_ISSUE:--}"
  phase="${AUTO_PHASE:--}"

  # --- stderr (human) ---
  if [[ -n "$cause" ]]; then
    printf '%s [%-5s] %s issue=%s phase=%s cause=%s%s\n' \
      "$ts" "$lvl" "$evt" "$issue" "$phase" "$cause" \
      "${msg:+ -- $msg}" >&2
  else
    printf '%s [%-5s] %s issue=%s phase=%s%s\n' \
      "$ts" "$lvl" "$evt" "$issue" "$phase" \
      "${msg:+ -- $msg}" >&2
  fi

  # --- NDJSON (machine) ---
  # Best-effort: never let a logging failure abort the caller (set -e safe).
  local path
  path="$(_auto_log_path)"
  if mkdir -p "${AUTO_LOG_DIR}" 2>/dev/null; then
    printf '{"ts":"%s","run":"%s","lvl":"%s","evt":"%s","issue":"%s","phase":"%s","cause":"%s","msg":"%s"}\n' \
      "$(_auto_json_escape "$ts")" \
      "$(_auto_json_escape "$run")" \
      "$lvl" \
      "$(_auto_json_escape "$evt")" \
      "$(_auto_json_escape "$issue")" \
      "$(_auto_json_escape "$phase")" \
      "$(_auto_json_escape "$cause")" \
      "$(_auto_json_escape "$msg")" \
      >> "$path" 2>/dev/null || true
  fi
}

# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #

# log_info <evt> [msg...]
log_info() {
  local evt="${1:?log_info: evt required}"; shift || true
  _auto_log_emit "INFO" "$evt" "" "$@"
}

# log_debug <evt> [msg...]   (suppressed unless AUTO_VERBOSE=1)
log_debug() {
  [[ "${AUTO_VERBOSE:-0}" == "1" ]] || return 0
  local evt="${1:?log_debug: evt required}"; shift || true
  _auto_log_emit "DEBUG" "$evt" "" "$@"
}

# log_error <evt> <cause> [msg...]
log_error() {
  local evt="${1:?log_error: evt required}"
  local cause="${2:?log_error: cause required}"
  shift 2 || true
  _auto_log_emit "ERROR" "$evt" "$cause" "$@"
}
