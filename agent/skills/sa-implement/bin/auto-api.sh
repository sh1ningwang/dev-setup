#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-api.sh — the agent-facing verb layer for the daemon-orchestrated sa-implement loop.
#
# WHY THIS EXISTS (agent-agnostic redesign):
#   The implementation loop is now split into two cooperating processes:
#     * bin/auto-daemon.sh  — a long-running, DETERMINISTIC background process that owns
#                             cadence (poll every ~15m or on a done-report), reads the
#                             GitHub issue queue, and TRIGGERS the main agent session.
#     * the main agent session (opencode / codex / claude, run interactively) — the
#                             COGNITIVE worker that decides which issue to do and does it.
#   The agent must never touch git/GitHub directly. Instead it calls the verbs below, so
#   every mutation flows through the same audited git+gh engine (bin/ + lib/), pinned to the
#   one account the daemon resolved. This file is that single call surface — host-neutral,
#   so the exact same contract works whether the host is opencode, codex, or claude.
#
# This is a THIN dispatcher: it parses a verb, then delegates to the UNMODIFIED engine
# scripts. It owns no safety logic of its own — the engine scripts remain authoritative.
#
# Run-state contract:
#   The daemon writes .auto/daemon/run.env at start (REPO, CONTROL_ISSUE, STATUS_ISSUE,
#   RUN_ID, THEME, AUTO_GH_ACCOUNT). Every verb sources it, so the agent never
#   passes run-scoped ids by hand. The per-issue runner id (needed so finish/escalate
#   release the SAME lease that prep took) is persisted to .auto/daemon/runner-<N> by `prep`
#   and read back by `finish`/`escalate`/`release`.
#
# Verbs (all print machine-readable lines on stdout; details per verb below):
#   queue                                  list the prioritized eligible-issue candidates (JSON)
#   prep    <N>                            claim issue N + cut its worktree/branch
#   commit  --dir <wt> --message <msg>     validate via commit-gate then commit
#   finish  <N> --worktree <wt> --branch <b>   push -> PR (base-locked) -> merge-when-green
#   escalate <N> <reason>                  human-gated escalation (auto:hold follow-up)
#   release  <N> <reason>                  recoverable release (re-queue the issue)
#   kill-check                             KILLED <source> | LIVE
#   status   <msg...>                      append a progress note to the per-run status issue
#
# Exit codes pass through the underlying engine script (see lib/constants.sh §EX_*).
#
# Depends ONLY on: git, gh, jq + the sibling engine scripts. git+gh only for mutation.
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
# shellcheck source=../lib/git.sh
source "${_SELF_DIR}/../lib/git.sh"

export AUTO_PHASE="${AUTO_PHASE:-api}"

# Daemon-published run state. Locations mirror lib/constants.sh (.auto/ is disposable).
AUTO_DAEMON_DIR="${AUTO_CACHE_DIR}/daemon"
AUTO_RUN_ENV_FILE="${AUTO_DAEMON_DIR}/run.env"

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

# --------------------------------------------------------------------------- #
# Load the daemon's run state. Without it there is no run to act on — fail loud
# rather than silently operate with half a context (user error-handling rule).
# --------------------------------------------------------------------------- #
load_run_env() {
  if [[ ! -f "$AUTO_RUN_ENV_FILE" ]]; then
    log_error "api_no_run" "no-run-env" "daemon run state not found at ${AUTO_RUN_ENV_FILE}; start the daemon first"
    echo "ERROR no-daemon" >&2
    exit "$EX_ERR"
  fi
  # shellcheck disable=SC1090
  source "$AUTO_RUN_ENV_FILE"
  : "${AUTO_RUN_ID:?run.env missing AUTO_RUN_ID}"
  : "${CONTROL_ISSUE:?run.env missing CONTROL_ISSUE}"
  : "${REPO:?run.env missing REPO}"
  export AUTO_RUN_ID GH_REPO="$REPO"
  STATUS_ISSUE="${STATUS_ISSUE:-}"
  THEME="${THEME:-}"
  # Re-assert the daemon's pinned account; the engine hard-refuses any drift.
  gh_select_account >/dev/null || { echo "ERROR account-drift" >&2; exit "$EX_PREFLIGHT_ACCOUNT"; }
}

# Per-issue runner id file (keeps prep's claim and finish's release on one identity).
runner_file() { printf '%s/runner-%s' "$AUTO_DAEMON_DIR" "$1"; }

new_runner_id() {
  printf '%s-%s-%s-%s-%s' "$AUTO_RUNNER_PREFIX" "$(hostname -s 2>/dev/null || echo host)" \
    "$$" "$(date +%s)" "${RANDOM}"
}

# Map a type:<label> to the conventional branch type token git_branch_name accepts.
branch_type_for() {
  case "$1" in
    feature) echo "feat" ;;
    bug)     echo "fix" ;;
    chore|spike|docs|refactor|perf|test) echo "$1" ;;
    *)       echo "chore" ;;
  esac
}

# =========================================================================== #
# queue — the candidate list the agent picks from (decision B: the AGENT decides
# which issue to work; the daemon/engine only surfaces the prioritized options).
# =========================================================================== #
cmd_queue() {
  load_run_env
  gh_queue_list "$THEME"
}

# =========================================================================== #
# prep <N> — claim a SPECIFIC issue the agent chose, then cut its worktree/branch.
# Composed from the unmodified engine (auto-claim.sh + auto-worktree.sh) because
# auto-iterate.sh --phase prep self-selects; here the agent has already decided.
# Prints: PREP issue=<N> branch=<b> worktree=<path> runner=<id>
# =========================================================================== #
cmd_prep() {
  local n="${1:?prep requires an issue number}"
  [[ "$n" =~ ^[0-9]+$ ]] || { log_error "api_prep" "bad-issue" "issue must be a number: $n"; exit "$EX_ERR"; }
  load_run_env
  export AUTO_ISSUE="$n"

  # Resolve type + title from the issue so the branch name is canonical.
  local meta type_label type title
  meta="$(gh_issue_view "$n" "title,labels")" || { log_error "api_prep" "view-failed" "issue=$n"; exit "$EX_ERR"; }
  title="$(printf '%s' "$meta" | jq -r '.title // ""')"
  type_label="$(printf '%s' "$meta" | jq -r '[.labels[].name | select(startswith("type:"))][0] // "type:chore" | ltrimstr("type:")')"
  type="$(branch_type_for "$type_label")"
  local branch; branch="$(git_branch_name "$type" "$n" "$title")"

  # Stable per-issue runner; persist BEFORE claiming so a crash still leaves the id.
  local runner; runner="$(new_runner_id)"
  mkdir -p "$AUTO_DAEMON_DIR"
  printf '%s' "$runner" > "$(runner_file "$n")"

  # Claim (additive lease + tie-break). Route the engine's exit codes verbatim.
  local rc=0
  AUTO_RUNNER_ID="$runner" "${BIN}/auto-claim.sh" "$n" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    case "$rc" in
      "$EX_CLAIM_LOST")    echo "PREP issue=$n reason=claim-lost" ;;
      "$EX_NOT_CLAIMABLE") echo "PREP issue=$n reason=not-claimable" ;;
      *)                   echo "PREP issue=$n reason=claim-error" ;;
    esac
    exit "$rc"
  fi

  # Worktree+branch from origin/develop-auto, enforcing the concurrency ceiling.
  local path
  if ! path="$(AUTO_RUNNER_ID="$runner" "${BIN}/auto-worktree.sh" add \
        --issue "$n" --branch "$branch" --repo "$REPO")"; then
    rc=$?
    # A worktree failure after a won claim must not strand the lease — release it.
    AUTO_RUNNER_ID="$runner" "${BIN}/auto-release.sh" "$n" "worktree-failed" --runner "$runner" || true
    echo "PREP issue=$n reason=worktree-error"; exit "$rc"
  fi

  echo "PREP issue=$n branch=$branch worktree=$path runner=$runner"
}

# =========================================================================== #
# commit — validate the staged tree via the gate, then commit (never bypass it).
# =========================================================================== #
cmd_commit() {
  local dir="" message=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)     dir="${2:?--dir requires a path}"; shift 2 ;;
      --message) message="${2:?--message requires text}"; shift 2 ;;
      *) log_error "api_commit" "unknown-arg" "unknown argument: $1"; exit "$EX_ERR" ;;
    esac
  done
  [[ -n "$dir" && -n "$message" ]] || { log_error "api_commit" "missing-arg" "need --dir and --message"; exit "$EX_ERR"; }
  load_run_env
  "${BIN}/commit-gate.sh" --dir "$dir" --message "$message"
  git -C "$dir" commit -m "$message"
  echo "COMMITTED dir=$dir"
}

# =========================================================================== #
# finish <N> — hand the merged-ready issue back to the engine: push -> base-locked
# PR -> merge-when-green -> release. auto-iterate.sh --phase finish is already
# issue-specific, so this is a direct pass-through (carrying the SAME runner).
# =========================================================================== #
cmd_finish() {
  local n="${1:?finish requires an issue number}"; shift
  [[ "$n" =~ ^[0-9]+$ ]] || { log_error "api_finish" "bad-issue" "issue must be a number: $n"; exit "$EX_ERR"; }
  local wt="" branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --worktree) wt="${2:?--worktree requires a path}"; shift 2 ;;
      --branch)   branch="${2:?--branch requires a name}"; shift 2 ;;
      *) log_error "api_finish" "unknown-arg" "unknown argument: $1"; exit "$EX_ERR" ;;
    esac
  done
  [[ -n "$wt" && -n "$branch" ]] || { log_error "api_finish" "missing-arg" "need --worktree and --branch"; exit "$EX_ERR"; }
  load_run_env
  local runner=""; [[ -f "$(runner_file "$n")" ]] && runner="$(cat "$(runner_file "$n")")"
  AUTO_RUNNER_ID="$runner" "${BIN}/auto-iterate.sh" --phase finish \
    --issue "$n" --worktree "$wt" --branch "$branch" \
    --control "$CONTROL_ISSUE" --run-id "$AUTO_RUN_ID" --repo "$REPO"
}

# =========================================================================== #
# escalate / release — human-gated hard stop vs recoverable re-queue.
# =========================================================================== #
cmd_escalate() {
  local n="${1:?escalate requires an issue number}"; local reason="${2:-escalate}"
  load_run_env
  local runner=""; [[ -f "$(runner_file "$n")" ]] && runner="$(cat "$(runner_file "$n")")"
  "${BIN}/auto-release.sh" "$n" "$reason" --outcome hard --runner "$runner"
  echo "ESCALATED issue=$n"
}

cmd_release() {
  local n="${1:?release requires an issue number}"; local reason="${2:-recoverable}"
  load_run_env
  local runner=""; [[ -f "$(runner_file "$n")" ]] && runner="$(cat "$(runner_file "$n")")"
  "${BIN}/auto-release.sh" "$n" "$reason" --runner "$runner"
  echo "RELEASED issue=$n"
}

# =========================================================================== #
# kill-check / status — the agent's read of the kill-switch and its progress note.
# =========================================================================== #
cmd_kill_check() {
  load_run_env
  "${BIN}/auto-kill.sh" --control "$CONTROL_ISSUE" --repo "$REPO"
}

cmd_status() {
  load_run_env
  local msg="$*"
  [[ -n "$msg" ]] || { log_error "api_status" "no-msg" "status requires a message"; exit "$EX_ERR"; }
  if [[ -z "$STATUS_ISSUE" || "$STATUS_ISSUE" == "-" ]]; then
    log_info "api_status" "no status issue configured; skipping note"
    return 0
  fi
  gh_issue_comment "$STATUS_ISSUE" "$msg"
  echo "STATUS_POSTED issue=$STATUS_ISSUE"
}

# --------------------------------------------------------------------------- #
# Dispatch.
# --------------------------------------------------------------------------- #
[[ $# -ge 1 ]] || { log_error "api_args" "no-verb" "expected a verb; see --help"; exit "$EX_ERR"; }
case "${1:-}" in -h|--help) print_help ;; esac
VERB="$1"; shift
case "$VERB" in
  queue)      cmd_queue "$@" ;;
  prep)       cmd_prep "$@" ;;
  commit)     cmd_commit "$@" ;;
  finish)     cmd_finish "$@" ;;
  escalate)   cmd_escalate "$@" ;;
  release)    cmd_release "$@" ;;
  kill-check) cmd_kill_check "$@" ;;
  status)     cmd_status "$@" ;;
  *) log_error "api_args" "unknown-verb" "unknown verb: $VERB"; exit "$EX_ERR" ;;
esac
