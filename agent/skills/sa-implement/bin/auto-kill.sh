#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-kill.sh — the SINGLE canonical kill-switch check for /auto.
#
# This is the ONE place /auto decides whether it has been told to stop. Both the
# in-session /loop tick and the out-of-session cron watchdog call this identical
# check (decisions.md §4, architecture §3.5), so there is exactly one contract.
#
# A run is KILLED if EITHER signal is set:
#   PRIMARY  : label `auto:stop` (AUTO_LABEL_STOP) on the pinned #auto-control
#              issue (AUTO_CONTROL_MARKER / AUTO_CONTROL_TITLE). One tap on the
#              GitHub mobile issue UI flips it.
#   FALLBACK : file `.auto/STOP` (AUTO_STOP_FILE_PATH) present on the develop-auto
#              branch (AUTO_BASE_BRANCH), read REMOTELY via `gh api .../contents`
#              so a local `.gitignore` is irrelevant.
#
# Either signal => killed. The decision is CACHED for AUTO_KILL_POLL_CACHE seconds
# (default 20) per process+repo, in AUTO_KILL_CACHE_FILE, to bound API calls when
# the switch is polled at five points per iteration under concurrency.
#
# Usage:
#   auto-kill.sh [--control <issue#>] [--repo <owner/repo>] [--no-cache] [--quiet]
#                [--clear-cache]
#
#   --control <issue#>  the pinned #auto-control issue number. If omitted it is
#                       LOCATED via the AUTO_CONTROL_MARKER search (slower; pass it
#                       when known, e.g. from preflight's CONTROL_ISSUE line).
#   --repo <owner/repo> operate on this repo (defaults to the current repo).
#   --no-cache          ignore + do not write the cache (force a live check).
#   --clear-cache       delete the cache file and exit 0 (used on resume).
#   --quiet             suppress the human KILLED/LIVE line on stdout.
#
# Stdout: exactly one line unless --quiet:
#   KILLED <source>     where <source> in {label,stop-file}
#   LIVE                kill-switch not engaged.
#
# Exit codes:
#   0   KILLED — the kill-switch IS engaged (caller must stop). (NOTE: 0 == killed,
#       per the phase contract; this mirrors `grep -q` "found == success".)
#   1   LIVE   — not killed; the run may continue.
#   (Other EX_* only on a hard argument error.)
#
# Depends ONLY on: git, gh, jq. Sources constants/log/gh.
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_SELF_DIR}/../lib/constants.sh"
# shellcheck source=../lib/log.sh
source "${_SELF_DIR}/../lib/log.sh"
# shellcheck source=../lib/gh.sh
source "${_SELF_DIR}/../lib/gh.sh"

export AUTO_PHASE="${AUTO_PHASE:-kill-check}"

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
CONTROL_ISSUE=""
REPO=""
USE_CACHE=1
QUIET=0
CLEAR_CACHE=0

# Print the leading header comment block (top-of-file usage) and exit 0.
print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --control)     CONTROL_ISSUE="${2:?--control requires an issue#}"; shift 2 ;;
    --repo)        REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --no-cache)    USE_CACHE=0; shift ;;
    --clear-cache) CLEAR_CACHE=1; shift ;;
    --quiet)       QUIET=1; shift ;;
    -h|--help)     print_help ;;
    *)
      log_error "kill_args" "unknown-arg" "unknown argument: $1"
      exit "$EX_ERR" ;;
  esac
done

# --clear-cache: drop the cache so the next check is live (used on resume), exit 0.
if [[ "$CLEAR_CACHE" -eq 1 ]]; then
  rm -f "$AUTO_KILL_CACHE_FILE" 2>/dev/null || true
  log_debug "kill_cache_clear" "removed ${AUTO_KILL_CACHE_FILE}"
  exit "$EX_OK"
fi

# A pinned --repo is threaded to every gh call so the check works headlessly from
# anywhere (cron, watchdog) without a checkout. Empty => the current repo.
GH_REPO_ARGS=()
[[ -n "$REPO" ]] && GH_REPO_ARGS=(--repo "$REPO")

# --------------------------------------------------------------------------- #
# Cache: a single line "<epoch> KILLED <source>" or "<epoch> LIVE". Fresh within
# AUTO_KILL_POLL_CACHE seconds. The cache is per repo-root (AUTO_KILL_CACHE_FILE is
# under .auto/), which is exactly the granularity we want (one cache per clone).
# --------------------------------------------------------------------------- #
_now() { date -u +%s; }

# _emit <result-token> [source] : print the human line (unless quiet) and exit with
# the contract code (0 KILLED / 1 LIVE).
_emit() {
  local result="$1" source="${2:-}"
  if [[ "$result" == "KILLED" ]]; then
    [[ "$QUIET" -eq 1 ]] || printf 'KILLED %s\n' "$source"
    exit "$EX_OK"
  fi
  [[ "$QUIET" -eq 1 ]] || printf 'LIVE\n'
  exit "$EX_ERR"
}

# Try the cache first (unless --no-cache). A malformed/stale line is ignored.
if [[ "$USE_CACHE" -eq 1 && -f "$AUTO_KILL_CACHE_FILE" ]]; then
  cached_line="$(cat "$AUTO_KILL_CACHE_FILE" 2>/dev/null || true)"
  cached_ts="${cached_line%% *}"
  if [[ "$cached_ts" =~ ^[0-9]+$ ]]; then
    age=$(( $(_now) - cached_ts ))
    if (( age >= 0 && age < AUTO_KILL_POLL_CACHE )); then
      rest="${cached_line#* }"            # strip the leading epoch.
      result="${rest%% *}"                # KILLED|LIVE
      source="${rest#* }"; [[ "$source" == "$result" ]] && source=""
      log_debug "kill_cache_hit" "age=${age}s result=${result} ${source}"
      _emit "$result" "$source"
    fi
  fi
fi

# --------------------------------------------------------------------------- #
# Cache miss / forced: write the fresh decision back to the cache, then emit.
# --------------------------------------------------------------------------- #
_cache_and_emit() {
  local result="$1" source="${2:-}"
  if [[ "$USE_CACHE" -eq 1 ]]; then
    mkdir -p "$AUTO_CACHE_DIR" 2>/dev/null || true
    if [[ "$result" == "KILLED" ]]; then
      printf '%s KILLED %s\n' "$(_now)" "$source" > "$AUTO_KILL_CACHE_FILE" 2>/dev/null || true
    else
      printf '%s LIVE\n' "$(_now)" > "$AUTO_KILL_CACHE_FILE" 2>/dev/null || true
    fi
  fi
  _emit "$result" "$source"
}

# --------------------------------------------------------------------------- #
# Locate the #auto-control issue if not provided. Best-effort: a search failure or
# a missing control issue is NOT itself a kill (the fallback file is still checked).
# --------------------------------------------------------------------------- #
locate_control_issue() {
  gh issue list "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" --state open \
      --search "${AUTO_CONTROL_MARKER} in:body" \
      --json number,body --limit 30 2>/dev/null \
    | jq -r --arg m "${AUTO_CONTROL_MARKER}" \
        '.[] | select(.body|contains($m)) | .number' 2>/dev/null \
    | head -n1 || true
}

if [[ -z "$CONTROL_ISSUE" ]]; then
  CONTROL_ISSUE="$(locate_control_issue)"
  [[ -n "$CONTROL_ISSUE" ]] && log_debug "kill_control_located" "#${CONTROL_ISSUE}"
fi

# --------------------------------------------------------------------------- #
# PRIMARY — auto:stop label on the pinned #auto-control issue.
# --------------------------------------------------------------------------- #
if [[ -n "$CONTROL_ISSUE" ]]; then
  labels="$(gh issue view "$CONTROL_ISSUE" "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" \
              --json labels --jq '.labels[].name' 2>/dev/null || true)"
  if printf '%s\n' "$labels" | grep -qx -- "$AUTO_LABEL_STOP"; then
    log_info "kill_switch" "ENGAGED via label ${AUTO_LABEL_STOP} on #auto-control #${CONTROL_ISSUE}"
    _cache_and_emit "KILLED" "label"
  fi
  log_debug "kill_label_clear" "${AUTO_LABEL_STOP} absent on #${CONTROL_ISSUE}"
else
  # No control issue yet (preflight not run, or transient search failure). The
  # primary signal cannot be present without it; fall through to the fallback.
  log_debug "kill_no_control" "no #auto-control located; checking fallback only"
fi

# --------------------------------------------------------------------------- #
# FALLBACK — .auto/STOP file present on develop-auto (read remotely, no checkout).
#   gh_remote_file_exists honours --repo via the cached slug only for the current
#   repo, so when --repo is passed we hit the contents API directly to stay headless.
# --------------------------------------------------------------------------- #
stop_file_present() {
  if [[ -n "$REPO" ]]; then
    gh api "repos/${REPO}/contents/${AUTO_STOP_FILE_PATH}?ref=${AUTO_BASE_BRANCH}" \
      >/dev/null 2>&1
  else
    gh_remote_file_exists "$AUTO_STOP_FILE_PATH" "$AUTO_BASE_BRANCH"
  fi
}

if stop_file_present; then
  log_info "kill_switch" "ENGAGED via ${AUTO_STOP_FILE_PATH} on ${AUTO_BASE_BRANCH}"
  _cache_and_emit "KILLED" "stop-file"
fi
log_debug "kill_stopfile_clear" "${AUTO_STOP_FILE_PATH} absent on ${AUTO_BASE_BRANCH}"

# --------------------------------------------------------------------------- #
# Neither signal set => LIVE.
# --------------------------------------------------------------------------- #
_cache_and_emit "LIVE"
