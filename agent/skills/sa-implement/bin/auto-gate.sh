#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-gate.sh — the single stop-condition gate `should_continue` (decisions.md §6;
# spec-concurrency §6; architecture §3.5). Evaluated at the TOP of every iteration
# (gate point 1) by /loop, cron, and the portable driver alike.
#
# It answers ONE question — should /auto start another iteration? — by evaluating
# the stop conditions in a FIXED priority order (first match wins). v1 has NO cost
# ceiling (decisions.md D7); the stop conditions are exactly:
#
#   1. kill-switch  (auto-kill.sh: auto:stop label OR .auto/STOP)  -> STOP kill-switch
#   2. time         (now >= --until, or start + --duration)        -> STOP time
#   3. budget       (--max-prs reached; --max-escalations reached) -> STOP max-prs
#                                                                     /max-escalations
#   4. backlog      (no eligible issues): --once -> STOP backlog-empty;
#                   otherwise IDLE-BACKOFF (sleep, then re-evaluate so the run keeps
#                   polling for newly-filed/--seeded work) rather than exiting.
#   5. operator     (.auto/.stopflag sentinel set by a SIGTERM trap)-> STOP operator
#   else                                                           -> CONTINUE
#
# Stdout (terminal sentinels, decisions.md §11): EXACTLY one of:
#   CONTINUE
#   STOP <reason>     reason in {kill-switch,time,max-prs,max-escalations,
#                                backlog-empty,operator}
#
# Exit codes:
#   0   printed CONTINUE (start another iteration).
#   0   printed STOP <reason> too — the gate's RESULT is on stdout, not the exit
#       code; the driver reads the sentinel line. (A non-zero exit is reserved for a
#       hard argument/dependency error so a malformed call never looks like "stop".)
#   1   hard argument / dependency error (NOT a stop decision).
#
# Usage:
#   auto-gate.sh [--until <iso8601|epoch>] [--duration <Nh|Nm|Ns>] [--start <epoch>]
#                [--max-prs <n>] [--pr-count <n>]
#                [--max-escalations <n>] [--escalation-count <n>]
#                [--control <issue#>] [--repo <owner/repo>]
#                [--theme <label>] [--once] [--no-backoff]
#                [--backoff <seconds>]
#
#   --until <t>            stop AT this instant (ISO-8601 UTC or epoch seconds).
#   --duration <dur>       stop after this span from --start (e.g. 8h, 90m, 30s).
#                          If both --until and --duration are given, the EARLIER wins.
#   --start <epoch>        run start epoch (defaults to now if a --duration is given
#                          without it). /loop+cron pass the SAME persisted start so
#                          both agree on the deadline.
#   --max-prs <n>          PR ceiling for the run (0 = unlimited; AUTO_MAX_PRS_DEFAULT).
#   --pr-count <n>         PRs this run has already opened (the driver tracks this).
#   --max-escalations <n>  escalation-chain ceiling (default MAX_ESCALATIONS=5).
#   --escalation-count <n> escalations this run has already filed.
#   --control <issue#>     pinned #auto-control issue (threaded to auto-kill.sh).
#   --repo <owner/repo>    operate on this repo (threaded to gh queries).
#   --theme <label>        scope the backlog query to this extra label (--theme/--label).
#   --once                 single-shot mode: an empty backlog STOPS (no idle-backoff).
#   --no-backoff           on empty backlog, return STOP backlog-empty immediately
#                          (do not sleep). Like --once for the backlog branch only.
#   --backoff <seconds>    idle sleep before re-checking the backlog (default below).
#
# Depends ONLY on: git, gh, jq, date. Sources constants/log/gh; shells out to
# auto-kill.sh for the kill-switch (single canonical check).
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_SELF_DIR}/../lib/constants.sh"
# shellcheck source=../lib/log.sh
source "${_SELF_DIR}/../lib/log.sh"
# shellcheck source=../lib/gh.sh
source "${_SELF_DIR}/../lib/gh.sh"

export AUTO_PHASE="${AUTO_PHASE:-gate}"

# Default idle-backoff between empty-backlog re-checks (seconds). Bounded so a
# long-running idle run polls for newly-filed/--seeded work at a sane cadence
# without hammering the API; overridable via --backoff or AUTO_IDLE_BACKOFF.
: "${AUTO_IDLE_BACKOFF:=60}"

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
UNTIL_RAW=""
DURATION_RAW=""
START_EPOCH=""
MAX_PRS="${AUTO_MAX_PRS_DEFAULT}"
PR_COUNT=0
MAX_ESCALATIONS_ARG="${MAX_ESCALATIONS}"
ESCALATION_COUNT=0
CONTROL_ISSUE=""
REPO=""
THEME=""
ONCE=0
NO_BACKOFF=0
BACKOFF="${AUTO_IDLE_BACKOFF}"

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --until)            UNTIL_RAW="${2:?--until requires a value}"; shift 2 ;;
    --duration)         DURATION_RAW="${2:?--duration requires a value}"; shift 2 ;;
    --start)            START_EPOCH="${2:?--start requires an epoch}"; shift 2 ;;
    --max-prs)          MAX_PRS="${2:?--max-prs requires a number}"; shift 2 ;;
    --pr-count)         PR_COUNT="${2:?--pr-count requires a number}"; shift 2 ;;
    --max-escalations)  MAX_ESCALATIONS_ARG="${2:?--max-escalations requires a number}"; shift 2 ;;
    --escalation-count) ESCALATION_COUNT="${2:?--escalation-count requires a number}"; shift 2 ;;
    --control)          CONTROL_ISSUE="${2:?--control requires an issue#}"; shift 2 ;;
    --repo)             REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --theme)            THEME="${2:?--theme requires a label}"; shift 2 ;;
    --once)             ONCE=1; shift ;;
    --no-backoff)       NO_BACKOFF=1; shift ;;
    --backoff)          BACKOFF="${2:?--backoff requires seconds}"; shift 2 ;;
    -h|--help)          print_help ;;
    *)
      log_error "gate_args" "unknown-arg" "unknown argument: $1"
      exit "$EX_ERR" ;;
  esac
done

# --------------------------------------------------------------------------- #
# Emit a terminal sentinel and exit 0 (the decision is the LINE, not the code).
# --------------------------------------------------------------------------- #
_continue() { printf '%s\n' "$AUTO_GATE_CONTINUE"; exit "$EX_OK"; }
_stop()     { printf '%s %s\n' "$AUTO_GATE_STOP" "$1"; exit "$EX_OK"; }

_now() { date -u +%s; }

# --------------------------------------------------------------------------- #
# Parse a duration (Nh|Nm|Ns|N -> seconds). Bare N is treated as seconds. Returns
# empty on a malformed value.
# --------------------------------------------------------------------------- #
_parse_duration_secs() {
  local d="${1:-}" num unit
  [[ -z "$d" ]] && { printf ''; return 0; }
  if [[ "$d" =~ ^([0-9]+)([smhd]?)$ ]]; then
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "$unit" in
      s|"") printf '%s' "$num" ;;
      m)    printf '%s' "$(( num * 60 ))" ;;
      h)    printf '%s' "$(( num * 3600 ))" ;;
      d)    printf '%s' "$(( num * 86400 ))" ;;
    esac
  else
    printf ''
  fi
}

# --------------------------------------------------------------------------- #
# Parse --until to an epoch. Accepts a bare epoch or an ISO-8601 UTC instant.
# Portable across GNU date and BSD/macOS date. Returns empty on failure.
# --------------------------------------------------------------------------- #
_parse_until_epoch() {
  local v="${1:-}"
  [[ -z "$v" ]] && { printf ''; return 0; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; return 0; fi
  local e
  # GNU date.
  e="$(date -u -d "$v" +%s 2>/dev/null || true)"
  if [[ -z "$e" ]]; then
    # BSD/macOS date (strip a trailing Z; try the common ISO format).
    local stripped="${v%Z}"
    e="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$stripped" +%s 2>/dev/null || true)"
  fi
  printf '%s' "$e"
}

# Compute the effective deadline epoch (earliest of --until and start+--duration).
_compute_deadline() {
  local until_e dur_s start_e dur_deadline=""
  until_e="$(_parse_until_epoch "$UNTIL_RAW")"
  dur_s="$(_parse_duration_secs "$DURATION_RAW")"
  if [[ -n "$dur_s" ]]; then
    start_e="${START_EPOCH:-$(_now)}"
    dur_deadline=$(( start_e + dur_s ))
  fi
  # Pick the earliest non-empty deadline.
  local best=""
  if [[ -n "$until_e" ]]; then best="$until_e"; fi
  if [[ -n "$dur_deadline" ]]; then
    if [[ -z "$best" || "$dur_deadline" -lt "$best" ]]; then best="$dur_deadline"; fi
  fi
  printf '%s' "$best"
}

# --------------------------------------------------------------------------- #
# 1. KILL-SWITCH (highest priority). Delegate to the single canonical check so
#    /loop and cron use IDENTICAL logic. auto-kill.sh exits 0 == KILLED.
# --------------------------------------------------------------------------- #
KILL_ARGS=()
[[ -n "$CONTROL_ISSUE" ]] && KILL_ARGS+=(--control "$CONTROL_ISSUE")
[[ -n "$REPO" ]] && KILL_ARGS+=(--repo "$REPO")
set +e
"${_SELF_DIR}/auto-kill.sh" --quiet "${KILL_ARGS[@]+"${KILL_ARGS[@]}"}"
kill_rc=$?
set -e
if [[ "$kill_rc" -eq 0 ]]; then
  log_info "gate_stop" "kill-switch engaged"
  _stop "$AUTO_STOP_REASON_KILL"
fi
log_debug "gate_kill_clear" "kill-switch not engaged"

# --------------------------------------------------------------------------- #
# 2. TIME (--until / --duration). The earliest deadline wins.
# --------------------------------------------------------------------------- #
DEADLINE="$(_compute_deadline)"
if [[ -n "$DEADLINE" ]]; then
  if [[ ! "$DEADLINE" =~ ^[0-9]+$ ]]; then
    log_error "gate_time" "bad-deadline" "could not parse --until '${UNTIL_RAW}' / --duration '${DURATION_RAW}'"
    exit "$EX_ERR"
  fi
  now="$(_now)"
  if (( now >= DEADLINE )); then
    log_info "gate_stop" "time deadline reached (now=${now} >= deadline=${DEADLINE})"
    _stop "$AUTO_STOP_REASON_TIME"
  fi
  log_debug "gate_time_ok" "now=${now} < deadline=${DEADLINE} ($(( DEADLINE - now ))s left)"
fi

# --------------------------------------------------------------------------- #
# 3. BUDGET — --max-prs then --max-escalations (decisions.md D7 / §2). 0 = unlimited.
# --------------------------------------------------------------------------- #
if [[ "$MAX_PRS" =~ ^[0-9]+$ ]] && (( MAX_PRS > 0 )) && (( PR_COUNT >= MAX_PRS )); then
  log_info "gate_stop" "max-prs reached (pr_count=${PR_COUNT} >= max=${MAX_PRS})"
  _stop "$AUTO_STOP_REASON_MAXPRS"
fi
log_debug "gate_maxprs_ok" "pr_count=${PR_COUNT} max=${MAX_PRS}"

if [[ "$MAX_ESCALATIONS_ARG" =~ ^[0-9]+$ ]] && (( MAX_ESCALATIONS_ARG > 0 )) \
   && (( ESCALATION_COUNT >= MAX_ESCALATIONS_ARG )); then
  log_info "gate_stop" "max-escalations reached (count=${ESCALATION_COUNT} >= max=${MAX_ESCALATIONS_ARG})"
  _stop "$AUTO_STOP_REASON_ESCALATIONS"
fi
log_debug "gate_maxesc_ok" "escalations=${ESCALATION_COUNT} max=${MAX_ESCALATIONS_ARG}"

# --------------------------------------------------------------------------- #
# 5(pre). OPERATOR stop sentinel — a SIGTERM/explicit-stop trap writes
#    AUTO_STOPFLAG_FILE; honour it BEFORE idling on an empty backlog so a stop
#    request during a backoff sleep takes effect promptly.
# --------------------------------------------------------------------------- #
if [[ -f "$AUTO_STOPFLAG_FILE" ]]; then
  log_info "gate_stop" "operator stop sentinel present (${AUTO_STOPFLAG_FILE})"
  _stop "$AUTO_STOP_REASON_OPERATOR"
fi

# --------------------------------------------------------------------------- #
# 4. BACKLOG — is there any eligible issue to pick up? gh_queue_list returns the
#    prioritized, filtered eligibility queue as a JSON array (gh.sh §3).
#    NB: --repo is honoured by exporting GH_REPO for the duration of the query so
#    the gh.sh wrapper (which has no --repo param) targets the right repo.
# --------------------------------------------------------------------------- #
backlog_count() {
  local arr count
  if [[ -n "$REPO" ]]; then
    arr="$(GH_REPO="$REPO" gh_queue_list "$THEME" 2>/dev/null || printf '[]')"
  else
    arr="$(gh_queue_list "$THEME" 2>/dev/null || printf '[]')"
  fi
  count="$(printf '%s' "$arr" | jq 'length' 2>/dev/null || echo 0)"
  printf '%s' "${count:-0}"
}

# Single-shot (--once / --no-backoff) stops on an empty backlog; otherwise we
# idle-backoff once and re-check so a live 24/7 run absorbs newly-filed work
# instead of exiting. The driver re-invokes the gate each tick, so a SINGLE
# backoff cycle here is the right granularity (the outer loop owns the cadence).
SINGLE_SHOT=0
{ [[ "$ONCE" -eq 1 ]] || [[ "$NO_BACKOFF" -eq 1 ]]; } && SINGLE_SHOT=1

count="$(backlog_count)"
if (( count > 0 )); then
  log_debug "gate_backlog_ok" "eligible=${count}"
  _continue
fi

# Backlog empty.
if [[ "$SINGLE_SHOT" -eq 1 ]]; then
  log_info "gate_stop" "backlog empty (single-shot)"
  _stop "$AUTO_STOP_REASON_BACKLOG"
fi

# Idle-backoff: sleep, then re-check ONCE. During the sleep, re-honour the operator
# sentinel and the kill-switch so a stop lands promptly even while idling.
log_info "gate_idle" "backlog empty; idle-backoff ${BACKOFF}s then re-check for new/--seeded work"
slept=0
while (( slept < BACKOFF )); do
  sleep 1
  slept=$(( slept + 1 ))
  if [[ -f "$AUTO_STOPFLAG_FILE" ]]; then
    log_info "gate_stop" "operator stop during idle-backoff"
    _stop "$AUTO_STOP_REASON_OPERATOR"
  fi
  set +e
  "${_SELF_DIR}/auto-kill.sh" --quiet "${KILL_ARGS[@]+"${KILL_ARGS[@]}"}"
  k=$?
  set -e
  if [[ "$k" -eq 0 ]]; then
    log_info "gate_stop" "kill-switch engaged during idle-backoff"
    _stop "$AUTO_STOP_REASON_KILL"
  fi
done

count="$(backlog_count)"
if (( count > 0 )); then
  log_info "gate_backlog_refill" "eligible=${count} after backoff"
  _continue
fi

log_info "gate_stop" "backlog still empty after idle-backoff"
_stop "$AUTO_STOP_REASON_BACKLOG"
