#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-daemon.sh — the long-running, DETERMINISTIC orchestrator for sa-implement.
#
# WHY THIS EXISTS (agent-agnostic redesign):
#   Replaces the Claude-only continuity (/loop + /schedule). One portable bash daemon
#   owns the loop's CADENCE and TRIGGERING; the interactive agent session owns the
#   COGNITION. The two talk over two FIFOs under .auto/daemon/:
#     * work.fifo   : daemon -> session   ("ROUND <n> <queue-json>"  or  "STOP <reason>")
#     * report.fifo : session -> daemon   ("REPORT result=<r> issue=<N|->")
#
#   Pacing is by FIFO back-pressure, not a busy timer: writing a ROUND blocks until the
#   session is free to read it, and reading the report blocks until the session finishes.
#   So while there is work the loop is purely report-driven (no overlap). Only when the
#   queue is EMPTY does the daemon idle-poll every --poll-interval seconds (default 15m).
#
# Lifecycle:
#   start  --repo <url> --account <name> --assignee <user> [--label L | --theme L]
#          [--duration X|--until T] [--once] [--max-prs N] [--max-escalations N]
#          [--poll-interval S] [--report-timeout S] [--verbose]
#       Runs in the FOREGROUND (the SKILL backgrounds it). Switches gh to <account> (the
#       caller passing it IS the switch authorization), runs preflight, publishes run
#       state, then loops. The queue is filtered to issues ASSIGNED TO <user> (and, when
#       given, also carrying <label>). On preflight failure it writes .auto/daemon/abort.
#   stop     Signal a running daemon to stop (also unblocks a waiting session) and clean up.
#   status   Print whether a daemon is running and its run ids.
#
# All GitHub mutation flows through the UNMODIFIED engine (bin/ + lib/), git+gh only.
#
# Exit codes: 0 clean stop; preflight codes 60-69 passed through; 1 generic/arg error.
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$_SELF_DIR"
# shellcheck source=../lib/constants.sh
source "${_SELF_DIR}/../lib/constants.sh"
# shellcheck source=../lib/log.sh
source "${_SELF_DIR}/../lib/log.sh"
# shellcheck source=../lib/gh.sh
source "${_SELF_DIR}/../lib/gh.sh"

export AUTO_PHASE="${AUTO_PHASE:-daemon}"

AUTO_DAEMON_DIR="${AUTO_CACHE_DIR}/daemon"
WORK_FIFO="${AUTO_DAEMON_DIR}/work.fifo"
REPORT_FIFO="${AUTO_DAEMON_DIR}/report.fifo"
PID_FILE="${AUTO_DAEMON_DIR}/daemon.pid"
RUN_ENV_FILE="${AUTO_DAEMON_DIR}/run.env"
READY_FILE="${AUTO_DAEMON_DIR}/ready"
ABORT_FILE="${AUTO_DAEMON_DIR}/abort"

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

# --------------------------------------------------------------------------- #
# FIFO helpers — bounded so a dead peer can never hang the survivor forever.
# read_fifo_line blocks for one line up to <timeout>s; rc 124 on timeout.
# write_fifo_line blocks until a reader consumes it, up to <timeout>s.
# --------------------------------------------------------------------------- #
read_fifo_line() { timeout "$2" head -n 1 "$1"; }            # prints the line; rc 124 = timeout
write_fifo_line() { timeout "$2" sh -c 'printf "%s\n" "$2" >"$1"' _ "$1" "$3"; }

# --------------------------------------------------------------------------- #
# Derive owner/repo from a GitHub URL or owner/repo string.
# --------------------------------------------------------------------------- #
derive_slug() {
  local u="$1"
  u="${u%.git}"
  case "$u" in
    https://github.com/*) printf '%s' "${u#https://github.com/}" ;;
    git@github.com:*)     printf '%s' "${u#git@github.com:}" ;;
    */*)                  printf '%s' "$u" ;;   # already owner/repo
    *) return 1 ;;
  esac
}

# =========================================================================== #
# start
# =========================================================================== #
cmd_start() {
  local repo_url="" account="" assignee="" theme="" duration="" until_at="" once=0
  local max_prs=0 max_esc="$MAX_ESCALATIONS" poll_interval=900 report_timeout=3600
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)            repo_url="${2:?--repo requires a url}"; shift 2 ;;
      --account)         account="${2:?--account requires a name}"; shift 2 ;;
      --assignee)        assignee="${2:?--assignee requires a name}"; shift 2 ;;
      --theme|--label)   theme="${2:?--theme/--label requires a label}"; shift 2 ;;
      --duration)        duration="${2:?--duration requires a value}"; shift 2 ;;
      --until)           until_at="${2:?--until requires a value}"; shift 2 ;;
      --once)            once=1; shift ;;
      --max-prs)         max_prs="${2:?--max-prs requires a number}"; shift 2 ;;
      --max-escalations) max_esc="${2:?--max-escalations requires a number}"; shift 2 ;;
      --poll-interval)   poll_interval="${2:?--poll-interval requires seconds}"; shift 2 ;;
      --report-timeout)  report_timeout="${2:?--report-timeout requires seconds}"; shift 2 ;;
      --verbose)         AUTO_VERBOSE=1; export AUTO_VERBOSE; shift ;;
      -h|--help)         print_help ;;
      *) log_error "daemon_args" "unknown-arg" "unknown argument: $1"; exit "$EX_ERR" ;;
    esac
  done
  [[ -n "$repo_url" && -n "$account" && -n "$assignee" ]] || { log_error "daemon_args" "missing" "need --repo, --account and --assignee (--label is optional)"; exit "$EX_ERR"; }

  local slug; slug="$(derive_slug "$repo_url")" || { log_error "daemon_start" "bad-url" "cannot parse repo from: $repo_url"; exit "$EX_ERR"; }

  # The working clone is the current directory; assert it before doing anything.
  git rev-parse --show-toplevel >/dev/null 2>&1 || {
    log_error "daemon_start" "no-clone" "run sa-implement from within the local clone of $slug"; exit "$EX_ERR"; }

  # Switch gh to the requested account. The user passing --account is the explicit
  # authorization to switch (git.md account rule); the engine then snapshots it and
  # hard-refuses any later drift.
  if ! gh auth switch --user "$account" >/dev/null 2>&1; then
    log_error "daemon_start" "switch-failed" "could not switch gh to account '$account' (is it logged in?)"; exit "$EX_PREFLIGHT_ACCOUNT"
  fi

  mkdir -p "$AUTO_DAEMON_DIR"
  rm -f "$READY_FILE" "$ABORT_FILE"
  [[ -p "$WORK_FIFO" ]]   || { rm -f "$WORK_FIFO";   mkfifo "$WORK_FIFO"; }
  [[ -p "$REPORT_FIFO" ]] || { rm -f "$REPORT_FIFO"; mkfifo "$REPORT_FIFO"; }

  # Refuse a second daemon on the same clone (one loop per project dir).
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    log_error "daemon_start" "already-running" "a daemon is already running (pid $(cat "$PID_FILE"))"; exit "$EX_ERR"
  fi
  echo "$$" > "$PID_FILE"

  local run_id; run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local start_epoch; start_epoch="$(date -u +%s)"
  export AUTO_RUN_ID="$run_id" GH_REPO="$slug"

  trap 'cmd_cleanup' EXIT INT TERM

  log_info "daemon_start" "run=$run_id repo=$slug account=$account theme=${theme:--}"

  # ---- Preflight (gate to autonomy). On failure, publish an abort marker. ----
  local pf rc=0
  pf="$("${BIN}/auto-preflight.sh" --run-id "$run_id")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf 'ABORT %s\n' "$rc" > "$ABORT_FILE"
    printf '%s\n' "$pf" >> "$ABORT_FILE"
    log_error "daemon_preflight" "abort-$rc" "preflight failed; see $ABORT_FILE"
    exit "$rc"
  fi
  local control status
  control="$(printf '%s\n' "$pf" | awk '/^CONTROL_ISSUE /{print $2}')"
  status="$(printf '%s\n' "$pf" | awk '/^STATUS_ISSUE /{print $2}')"

  # ---- Publish run state for auto-api.sh (the agent's verb layer). ----
  {
    printf 'AUTO_RUN_ID=%q\n' "$run_id"
    printf 'CONTROL_ISSUE=%q\n' "$control"
    printf 'STATUS_ISSUE=%q\n' "$status"
    printf 'REPO=%q\n' "$slug"
    printf 'THEME=%q\n' "$theme"
    printf 'ASSIGNEE=%q\n' "$assignee"
    printf 'AUTO_GH_ACCOUNT=%q\n' "$account"
  } > "$RUN_ENV_FILE"
  printf 'ready run=%s control=%s status=%s\n' "$run_id" "$control" "${status:--}" > "$READY_FILE"

  # ---- The cadence loop. ----
  daemon_loop "$control" "$theme" "$start_epoch" "$duration" "$until_at" \
    "$once" "$max_prs" "$max_esc" "$poll_interval" "$report_timeout" "$assignee"
}

# --------------------------------------------------------------------------- #
# daemon_loop — gate -> push a round -> await report; idle-poll when empty.
# --------------------------------------------------------------------------- #
daemon_loop() {
  local control="$1" theme="$2" start_epoch="$3" duration="$4" until_at="$5"
  local once="$6" max_prs="$7" max_esc="$8" poll="$9" report_to="${10}" assignee="${11}"
  local pr_count=0 esc_count=0 round=0

  while true; do
    # 1) Stop decision (kill-switch -> time -> budget -> backlog -> operator). We own
    #    pacing, so suppress the gate's own idle backoff (--no-backoff).
    local gate
    gate="$("${BIN}/auto-gate.sh" --start "$start_epoch" \
      ${duration:+--duration "$duration"} ${until_at:+--until "$until_at"} \
      --max-prs "$max_prs" --pr-count "$pr_count" \
      --max-escalations "$max_esc" --escalation-count "$esc_count" \
      --control "$control" ${theme:+--theme "$theme"} --repo "$GH_REPO" \
      --no-backoff ${once:+--once})" || true

    if [[ "$gate" == "$AUTO_GATE_STOP"* ]]; then
      local reason="${gate#"$AUTO_GATE_STOP" }"
      log_info "daemon_stop" "gate stop: $reason"
      # Best-effort: unblock a waiting session so it can disarm and report.
      write_fifo_line "$WORK_FIFO" 5 "STOP ${reason}" || true
      return 0
    fi

    # 2) Build the candidate queue for the agent to pick from (decision B).
    local queue count
    queue="$(gh_queue_list "$theme" "$assignee" 2>/dev/null || echo '[]')"
    count="$(printf '%s' "$queue" | jq 'length' 2>/dev/null || echo 0)"

    if [[ "$count" -eq 0 ]]; then
      [[ "$once" -eq 1 ]] && { write_fifo_line "$WORK_FIFO" 5 "STOP $AUTO_STOP_REASON_BACKLOG" || true; return 0; }
      log_debug "daemon_idle" "queue empty; idle-poll ${poll}s"
      sleep "$poll"
      continue
    fi

    # 3) Trigger the session with this round. The write blocks until the session is
    #    free to read it (natural back-pressure — no overlap with in-flight work).
    round=$((round + 1))
    log_info "daemon_round" "round=$round candidates=$count"
    if ! write_fifo_line "$WORK_FIFO" "$report_to" "ROUND ${round} ${queue}"; then
      log_debug "daemon_round" "no session consumed the round within ${report_to}s; re-gating"
      continue
    fi

    # 4) Await the session's report for this round (blocks until it finishes one issue).
    local rep rc=0
    rep="$(read_fifo_line "$REPORT_FIFO" "$report_to")" || rc=$?
    if [[ "$rc" -eq 124 ]]; then
      log_error "daemon_report" "report-timeout" "no report within ${report_to}s; re-gating"
      continue
    fi
    # rep = "REPORT result=<merged|pr-open|escalated|error|nothing> issue=<N|->"
    local result; result="$(printf '%s' "$rep" | sed -n 's/.*result=\([^ ]*\).*/\1/p')"
    case "$result" in
      merged)    pr_count=$((pr_count + 1)) ;;
      escalated) esc_count=$((esc_count + 1)) ;;
    esac
    log_info "daemon_report" "round=$round result=${result:-?} prs=$pr_count esc=$esc_count"
    # On a report we loop immediately (report-driven cadence while work exists).
  done
}

# =========================================================================== #
# stop / status / cleanup
# =========================================================================== #
cmd_stop() {
  if [[ ! -f "$PID_FILE" ]]; then echo "no daemon running"; return 0; fi
  local pid; pid="$(cat "$PID_FILE")"
  # Unblock a session that may be waiting on work.fifo, then signal the daemon.
  [[ -p "$WORK_FIFO" ]] && write_fifo_line "$WORK_FIFO" 5 "STOP $AUTO_STOP_REASON_OPERATOR" || true
  kill -TERM "$pid" 2>/dev/null || true
  echo "stopped daemon pid=$pid"
}

cmd_status() {
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "RUNNING pid=$(cat "$PID_FILE")"
    [[ -f "$RUN_ENV_FILE" ]] && grep -E '^(AUTO_RUN_ID|CONTROL_ISSUE|STATUS_ISSUE|REPO)=' "$RUN_ENV_FILE"
  else
    echo "STOPPED"
    [[ -f "$ABORT_FILE" ]] && { echo "last abort:"; cat "$ABORT_FILE"; }
  fi
}

cmd_cleanup() {
  rm -f "$PID_FILE" "$READY_FILE" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# Dispatch.
# --------------------------------------------------------------------------- #
[[ $# -ge 1 ]] || { log_error "daemon_args" "no-subcommand" "expected start|stop|status"; exit "$EX_ERR"; }
case "${1:-}" in -h|--help) print_help ;; esac
SUB="$1"; shift
case "$SUB" in
  start)  cmd_start "$@" ;;
  stop)   cmd_stop "$@" ;;
  status) cmd_status "$@" ;;
  *) log_error "daemon_args" "unknown-subcommand" "expected start|stop|status, got '$SUB'"; exit "$EX_ERR" ;;
esac
