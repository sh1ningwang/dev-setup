#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-iterate.sh — the deterministic, mutating phases of ONE /auto iteration.
#
# The native-Claude engine spine: `git`+`gh` ONLY (never the GitHub MCP), re-deriving
# 100% of its working set from GitHub at the top of every run, so it is safe to start
# with NO carried context and safe to `kill -9` between any two steps (architecture
# §7.1–7.2, state-model §6). It runs in TWO phases the /auto SESSION calls around the
# cognitive EXECUTE step (the session spawns the auto:<role> subagents — a shell cannot
# spawn in-session subagents):
#
#   --phase prep  (A→D): cold-boot → select/resume → claim → branch+worktree. Leaves the
#                 claim LIVE and prints one PREP line for the session.
#   [ EXECUTE ]   the SESSION runs the consensus design+review rounds and commits each accepted
#                 change via commit-gate.sh (SKILL.md §4.3). NOT in this file.
#   --phase finish (F→G): push → base-locked PR (auto-pr-create.sh) → green squash-merge
#                 (auto-merge-when-green.sh) → release. Prints one ITER line.
#
# Phases:
#   A  COLD-BOOT     re-derive state from GitHub (control issue, in-flight, open PRs).
#   B  CLAIM         auto-claim.sh — CAS-free additive lease + deterministic tie-break.
#   C  SELECT/RESUME top eligible issue by priority, OR resume a live-leased issue.
#   D  BRANCH        auto-worktree.sh — worktree + branch cut FROM origin/develop-auto.
#   F  PR            push → auto-pr-create.sh (base-locked + verified).
#   G  MERGE/RELEASE auto-merge-when-green.sh → close/escalate; always release the claim.
#
# Idempotent + crash-safe: an EXIT/INT/TERM trap releases the claim (auto-release.sh)
# even on crash; a successful `prep` SUPPRESSES that release so the claim survives for
# the session's EXECUTE + `finish`. Re-running resumes the same issue (worktree reuse,
# PR reuse by exact head branch). The kill-switch (auto-kill.sh) is checked at the 5
# documented points (state-model §4.2). --dry-run runs with NO remote mutation. Runner
# identity is shared across prep+finish via a session-passed AUTO_RUNNER_ID (so finish
# releases the lease prep took).
#
# Usage:
#   auto-iterate.sh --phase prep   [--theme <label>] [--concurrency <K>] [--context "<text>"]
#                                  [--control <issue#>] [--status <issue#>] [--run-id <id>]
#                                  [--repo <owner/repo>] [--dry-run] [--verbose]
#   auto-iterate.sh --phase finish --issue <N> --worktree <path> [--branch <name>]
#                                  [--control <issue#>] [--run-id <id>] [--context "<text>"]
#                                  [--repo <owner/repo>] [--dry-run] [--verbose]
#   (Export a stable AUTO_RUNNER_ID and pass it to BOTH phases of the same issue.)
#
# Stdout (machine-parseable terminal line, exactly one):
#   --phase prep:   PREP issue=<N|-> size=<S|M|L|XL|-> branch=<name|-> worktree=<path|-> reason=<token>
#   --phase finish: ITER <result> issue=<N|-> pr=<N|-> reason=<token>
#                     result ∈ {merged, pr-open, escalated, dry-run, error}
#
# Exit codes (constants.sh §10 — the session routes on these):
#   0   progress / clean no-op (prep: backlog-empty / not-claimable; finish: merged / pr-open).
#   2   kill-switch engaged at a check-point (clean stop).
#   11  claim lost (someone else holds a live lease) — try the next issue.
#   13  concurrency ceiling reached — back off.
#   69  gh account could not be resolved/asserted (preflight should have caught).
#   70-75 PR/merge failures (base-lock / push / verify / not-green / green-floor /
#       conflict) — surfaced after best-effort escalation.
#   1   generic / argument error.
#
# Depends ONLY on: git, gh, jq, python3 (+ gitleaks for the commit gate, via
# commit-gate.sh). Sources constants/log/gh/git/roles/lease; shells out to the sibling
# bin/*.sh by their documented contracts.
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="$(cd "${_SELF_DIR}/../lib" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_LIB}/constants.sh"
# shellcheck source=../lib/log.sh
source "${_LIB}/log.sh"
# shellcheck source=../lib/gh.sh
source "${_LIB}/gh.sh"
# shellcheck source=../lib/git.sh
source "${_LIB}/git.sh"
# shellcheck source=../lib/roles.sh
source "${_LIB}/roles.sh"
# shellcheck source=../lib/lease.sh
source "${_LIB}/lease.sh"          # shared lease-comment parsing (lease_live_owner, ...).

export AUTO_PHASE="iterate"

# =========================================================================== #
# Args.
# =========================================================================== #
ARG_ISSUE=""
THEME=""
CONCURRENCY="${AUTO_CONCURRENCY_DEFAULT}"
CONTEXT=""
CONTROL_ISSUE=""
STATUS_ISSUE=""
RUN_ID="${AUTO_RUN_ID:-}"
PHASE="prep"             # prep (A-D: claim+branch) | finish (F-G: PR+merge+release).
FINISH_WORKTREE=""       # --phase finish: the worktree the session ran EXECUTE in.
FINISH_BRANCH=""         # --phase finish: the head branch (else re-derived from labels).
REPO=""
DRY_RUN=0

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)       ARG_ISSUE="${2:?--issue requires a number}"; shift 2 ;;
    --phase)       PHASE="${2:?--phase requires prep|finish}"; shift 2 ;;
    --theme)       THEME="${2:?--theme requires a label}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:?--concurrency requires a number}"; shift 2 ;;
    --context)     CONTEXT="${2?--context requires text}"; shift 2 ;;
    --control)     CONTROL_ISSUE="${2:?--control requires an issue#}"; shift 2 ;;
    --status)      STATUS_ISSUE="${2:?--status requires an issue#}"; shift 2 ;;
    --run-id)      RUN_ID="${2:?--run-id requires a value}"; shift 2 ;;
    --worktree)    FINISH_WORKTREE="${2:?--worktree requires a path}"; shift 2 ;;
    --branch)      FINISH_BRANCH="${2:?--branch requires a name}"; shift 2 ;;
    --repo)        REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --verbose)     AUTO_VERBOSE=1; export AUTO_VERBOSE; shift ;;
    -h|--help)     print_help ;;
    *) log_error "iter_args" "unknown-arg" "unknown argument: $1"; exit "$EX_ERR" ;;
  esac
done

if [[ -n "$ARG_ISSUE" && ! "$ARG_ISSUE" =~ ^[0-9]+$ ]]; then
  log_error "iter_args" "bad-issue" "--issue must be a number: $ARG_ISSUE"; exit "$EX_ERR"
fi
if [[ ! "$CONCURRENCY" =~ ^[0-9]+$ ]] || (( CONCURRENCY < 1 )); then
  log_error "iter_args" "bad-concurrency" "--concurrency must be a positive integer: $CONCURRENCY"; exit "$EX_ERR"
fi

# A single run id is shared by /loop + cron so both agree on deadlines/state.
[[ -n "$RUN_ID" ]] || RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
export AUTO_RUN_ID="$RUN_ID"

# Thread --repo to every gh.sh wrapper (they read GH_REPO; they have no --repo param).
[[ -n "$REPO" ]] && export GH_REPO="$REPO"

# Stable runner identity for the WHOLE iteration so claim + release + lease share one id
# (auto-claim.sh / auto-release.sh both honour a pre-exported AUTO_RUNNER_ID).
if [[ -z "${AUTO_RUNNER_ID:-}" ]]; then
  AUTO_RUNNER_ID="${AUTO_RUNNER_PREFIX}-$(hostname -s 2>/dev/null || echo host)-$$-$(date +%s)-${RANDOM}"
fi
export AUTO_RUNNER_ID
readonly RUNNER_ID="$AUTO_RUNNER_ID"

log_info "iter_begin" "run=${RUN_ID} phase=${PHASE} runner=${RUNNER_ID} concurrency=${CONCURRENCY} dry_run=${DRY_RUN}${THEME:+ theme=${THEME}}${ARG_ISSUE:+ issue=${ARG_ISSUE}}"

# =========================================================================== #
# Terminal-result emission + claim-release trap (crash-safe; decisions.md §4).
# =========================================================================== #
CLAIMED_ISSUE=""          # set once we hold a claim; the trap releases it.
RELEASED=0                # set once a release (success/recoverable/hard) has run.
WORK_PR=""                # set once a PR is open/created for the issue.
ITER_REASON="-"           # last reason token (default for emit_and_exit's reason arg).

# emit_and_exit <result> <exit-code> [reason]
#   Print the single machine-parseable terminal line and exit with the given code.
#   Idempotent: only the first call wins (later trap-driven calls are suppressed).
emit_and_exit() {
  local result="$1" code="$2" reason="${3:-$ITER_REASON}"
  ITER_REASON="$reason"
  printf 'ITER %s issue=%s pr=%s reason=%s\n' \
    "$result" "${CLAIMED_ISSUE:--}" "${WORK_PR:--}" "$reason"
  log_info "iter_end" "result=${result} issue=${CLAIMED_ISSUE:--} pr=${WORK_PR:--} reason=${reason} code=${code}"
  exit "$code"
}

# release_claim <reason> [outcome]
#   Release the per-issue claim via auto-release.sh (the single sanctioned release
#   path). Best-effort + idempotent: never aborts the trap; only runs once.
release_claim() {
  local reason="$1" outcome="${2:-}"
  [[ -z "$CLAIMED_ISSUE" || "$RELEASED" == 1 ]] && return 0
  RELEASED=1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "iter_release_dry" "DRY-RUN: would release issue=${CLAIMED_ISSUE} reason=${reason} outcome=${outcome:-infer}"
    return 0
  fi
  local args=("$CLAIMED_ISSUE" "$reason" --runner "$RUNNER_ID")
  [[ -n "$outcome" ]] && args+=(--outcome "$outcome")
  [[ -n "$WORK_PR" ]] && args+=(--pr "$WORK_PR")
  [[ -n "$CONTEXT" ]] && args+=(--context "$CONTEXT")
  set +e
  "${_SELF_DIR}/auto-release.sh" "${args[@]}" >/dev/null 2>&1
  local rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || log_error "iter_release" "release-nonzero" "auto-release.sh rc=${rc} issue=${CLAIMED_ISSUE}"
}

# remove_worktree
#   Best-effort worktree cleanup. A pushed branch backing an open PR is preserved by
#   auto-worktree.sh's default PR-check.
remove_worktree() {
  [[ -z "$CLAIMED_ISSUE" || "$DRY_RUN" -eq 1 ]] && return 0
  set +e
  "${_SELF_DIR}/auto-worktree.sh" remove --issue "$CLAIMED_ISSUE" ${REPO:+--repo "$REPO"} >/dev/null 2>&1
  set -e
}

# on_exit — the crash-safe net. If we still hold an un-released claim when the script
# exits for ANY reason (including kill -9'd children / set -e abort), re-queue it as a
# RECOVERABLE failure so the work is not orphaned in auto:claimed (decisions.md §4 /
# auto-release.sh "fail-safe default = recoverable").
# shellcheck disable=SC2329  # invoked via the trap below.
on_exit() {
  local rc=$?
  if [[ -n "$CLAIMED_ISSUE" && "$RELEASED" != 1 ]]; then
    log_error "iter_trap" "uncaught-exit-rc-${rc}" "releasing claim on issue=${CLAIMED_ISSUE} (crash/abort safety net)"
    release_claim "trap-rc-${rc}"
  fi
  return 0
}
trap on_exit EXIT INT TERM

# =========================================================================== #
# kill_check <point>
#   The SINGLE canonical kill-switch check (auto-kill.sh; exit 0 == KILLED). Called
#   at the 5 documented points (state-model §4.2). On a kill: release any claim
#   (cooperative; the current atomic commit has already finished) and exit cleanly
#   with EX_PREFLIGHT_KILLSWITCH (2 — a clean stop, not an error; constants.sh §10).
# =========================================================================== #
kill_check() {
  local point="$1"
  local kargs=(--quiet)
  [[ -n "$CONTROL_ISSUE" ]] && kargs+=(--control "$CONTROL_ISSUE")
  [[ -n "$REPO" ]] && kargs+=(--repo "$REPO")
  set +e
  "${_SELF_DIR}/auto-kill.sh" "${kargs[@]}"
  local krc=$?
  set -e
  if [[ "$krc" -eq 0 ]]; then
    log_info "iter_kill" "kill-switch engaged at point '${point}'; stopping cooperatively"
    release_claim "kill-switch"
    emit_and_exit "killed" "$EX_PREFLIGHT_KILLSWITCH" "kill-switch"
  fi
  log_debug "iter_kill_clear" "kill-switch clear at point '${point}'"
}

# =========================================================================== #
# Small helpers.
# =========================================================================== #

# issue_label_value <issue-json> <prefix>  -> first label name starting with <prefix>.
issue_label_value() {
  printf '%s' "$1" | jq -r --arg p "$2" \
    '[.labels[].name | select(startswith($p))] | (.[0] // "")' 2>/dev/null || true
}

# size_from_labels <issue-json> -> S|M|L|XL (AUTO_SIZE_DEFAULT when missing/ambiguous).
size_from_labels() {
  local sz
  case "$(issue_label_value "$1" 'size:')" in
    "$AUTO_LABEL_SIZE_S")  sz="S" ;;
    "$AUTO_LABEL_SIZE_M")  sz="M" ;;
    "$AUTO_LABEL_SIZE_L")  sz="L" ;;
    "$AUTO_LABEL_SIZE_XL") sz="XL" ;;
    *)                     sz="$AUTO_SIZE_DEFAULT" ;;   # fail-safe toward more review.
  esac
  printf '%s' "$sz"
}

# branch_type_from_labels <issue-json> -> branch <type> token (AUTO_BRANCH_TYPES).
#   type:feature→feat, type:bug→fix, others map 1:1 (conventions §1). Default chore.
branch_type_from_labels() {
  case "$(issue_label_value "$1" 'type:')" in
    "$AUTO_LABEL_TYPE_FEATURE")  printf 'feat' ;;
    "$AUTO_LABEL_TYPE_BUG")      printf 'fix' ;;
    "$AUTO_LABEL_TYPE_SPIKE")    printf 'spike' ;;
    "$AUTO_LABEL_TYPE_REFACTOR") printf 'refactor' ;;
    "$AUTO_LABEL_TYPE_DOCS")     printf 'docs' ;;
    *)                           printf 'chore' ;;
  esac
}

# (rounds_for_size lived here: review-round budgets are now the session's concern in
# the EXECUTE phase — see SKILL.md §4.3 — so the shell no longer computes them.)

# Cold-start lease-owner resume is delegated to lib/lease.sh (lease_owned_by); that
# extractor used to be inlined here and is now shared across the bin/*.sh. (The old
# phase/round checkpoint pointer is gone — re-arm is the session's /loop concern now.)

# =========================================================================== #
# PHASE A — COLD-BOOT. Re-derive state from GitHub; nothing relies on carried
# context (architecture §7.1–7.2). Pin the account, prune crashed worktrees, locate
# the control issue if not supplied. KILL-CHECK POINT 1 (iteration top).
# =========================================================================== #
phase_a_coldboot() {
  export AUTO_PHASE="cold-boot"

  # Resolve the run identity (the ACTIVE local gh login) BEFORE any mutation.
  # In --dry-run the same read-only resolution runs; an identity-drift
  # mismatch still hard-fails so dry-run faithfully rehearses the real account guard.
  if ! gh_select_account >/dev/null; then
    log_error "iter_account" "account-resolve-failed" "could not resolve/assert the active gh account"
    emit_and_exit "error" "$EX_PREFLIGHT_ACCOUNT" "account"
  fi

  # KILL-CHECK 1 — iteration top, before selecting an issue.
  kill_check "iteration-top"

  # GC stale worktree admin entries from crashed runs so the local concurrency count
  # is honest (does not falsely trip the ceiling). Pure-local; safe under --dry-run.
  git_worktree_prune

  # Locate the pinned #auto-control issue if the driver did not pass it (preflight
  # normally does). Best-effort; the kill-check tolerates an absent control issue
  # (it then relies on the .auto/STOP fallback).
  if [[ -z "$CONTROL_ISSUE" ]]; then
    CONTROL_ISSUE="$(gh issue list ${REPO:+--repo "$REPO"} --state open \
        --search "${AUTO_CONTROL_MARKER} in:body" --json number,body --limit 30 2>/dev/null \
      | jq -r --arg m "$AUTO_CONTROL_MARKER" '.[] | select(.body|contains($m)) | .number' 2>/dev/null \
      | head -n1 || true)"
    [[ -n "$CONTROL_ISSUE" ]] && log_debug "iter_control_located" "#${CONTROL_ISSUE}"
  fi
  log_info "iter_coldboot" "control=#${CONTROL_ISSUE:--} status=#${STATUS_ISSUE:--}"
}

# =========================================================================== #
# PHASE B + C — SELECT/RESUME + CLAIM.
#
# RESUME first (cold-start): if THIS runner already holds a live lease on an issue
# (status:in-progress with our lease comment) we re-derive and continue THAT issue.
# Otherwise SELECT the top eligible issue by priority (gh_queue_list is already
# priority-sorted) and CLAIM it (auto-claim.sh). A specific --issue overrides.
#
# The concurrency ceiling is enforced by auto-worktree.sh at branch time (phase D);
# here we only refuse to claim a *new* issue when the global in-progress count is
# already at/over the ceiling (cheap pre-check; the worktree gate is authoritative).
# =========================================================================== #

# select_resume_issue -> echo the issue# to drive (claimed/owned), or empty for none.
#   Sets CLAIMED_ISSUE on success. Honours --dry-run (simulates the claim).
select_resume_issue() {
  export AUTO_PHASE="select"

  # ---- RESUME: an issue we already hold (status:in-progress + our live lease). ----
  # Cold-start: we cannot trust local memory, so query GitHub. Match a live lease
  # owned by THIS runner id; if found, that is the issue to continue.
  if [[ -z "$ARG_ISSUE" ]]; then
    local resume
    resume="$(gh issue list ${REPO:+--repo "$REPO"} --state open \
        --label "$AUTO_LABEL_STATUS_IN_PROGRESS" --json number --limit 50 2>/dev/null \
      | jq -r '.[].number' 2>/dev/null || true)"
    local cand
    for cand in $resume; do
      # We own this issue iff THIS runner holds the winning LIVE lease (lib/lease.sh
      # applies the full release/TTL/reclaim semantics — same logic as auto-claim.sh).
      local comments
      comments="$(gh_issue_comments_json "$cand" 2>/dev/null || echo '[]')"
      if lease_owned_by "$comments" "$RUNNER_ID"; then
        CLAIMED_ISSUE="$cand"
        log_info "iter_resume" "resuming issue=${cand} (live lease held by this runner)"
        printf '%s' "$cand"
        return 0
      fi
    done
  fi

  # ---- SELECT: a specific --issue, or the top eligible by priority. ----
  local target="$ARG_ISSUE"
  if [[ -z "$target" ]]; then
    local queue
    queue="$(gh_queue_list "$THEME" 2>/dev/null || printf '[]')"
    local qcount
    qcount="$(printf '%s' "$queue" | jq 'length' 2>/dev/null || echo 0)"
    if (( qcount == 0 )); then
      log_info "iter_no_work" "no eligible issues in the queue${THEME:+ (theme=${THEME})}"
      printf ''
      return 0
    fi
    target="$(printf '%s' "$queue" | jq -r '.[0].number' 2>/dev/null || true)"
    log_debug "iter_select" "queue depth=${qcount}; top issue=${target}"
  fi
  [[ -n "$target" && "$target" =~ ^[0-9]+$ ]] || { printf ''; return 0; }

  # Cheap global concurrency pre-check (the worktree gate at phase D is authoritative
  # and TOCTOU-honest). Skip when claiming a specific --issue we may already own.
  if [[ -z "$ARG_ISSUE" ]]; then
    local inprog
    inprog="$(gh_count_in_progress 2>/dev/null || echo 0)"
    [[ "$inprog" =~ ^[0-9]+$ ]] || inprog=0
    if (( inprog >= CONCURRENCY )); then
      log_info "iter_concurrency" "global in-progress=${inprog} >= concurrency=${CONCURRENCY}; not claiming new work"
      printf ''
      ITER_REASON="concurrency"
      return "$EX_CONCURRENCY"
    fi
  fi

  # ---- CLAIM (or simulate under --dry-run). ----
  if [[ "$DRY_RUN" -eq 1 ]]; then
    CLAIMED_ISSUE="$target"
    log_info "iter_claim_dry" "DRY-RUN: would claim issue=${target} as ${RUNNER_ID} (no writes)"
    printf '%s' "$target"
    return 0
  fi

  set +e
  "${_SELF_DIR}/auto-claim.sh" "$target" >/dev/null
  local crc=$?
  set -e
  case "$crc" in
    0)
      CLAIMED_ISSUE="$target"
      log_info "iter_claim_won" "claimed issue=${target} as ${RUNNER_ID}"
      printf '%s' "$target"
      return 0 ;;
    "$EX_CLAIM_LOST")
      log_info "iter_claim_lost" "issue=${target} claimed by another runner"
      printf ''
      ITER_REASON="claim-lost"
      return "$EX_CLAIM_LOST" ;;
    "$EX_NOT_CLAIMABLE")
      log_info "iter_not_claimable" "issue=${target} not claimable (closed/held/blocked)"
      printf ''
      ITER_REASON="not-claimable"
      return "$EX_NOT_CLAIMABLE" ;;
    "$EX_PREFLIGHT_ACCOUNT")
      log_error "iter_claim_account" "account" "claim failed: wrong gh account"
      printf ''
      return "$EX_PREFLIGHT_ACCOUNT" ;;
    *)
      log_error "iter_claim_err" "claim-error-${crc}" "issue=${target}"
      printf ''
      return "$EX_ERR" ;;
  esac
}

# =========================================================================== #
# PHASE D — BRANCH. Create/reuse the per-issue worktree + branch cut FROM
# origin/develop-auto, enforcing the concurrency ceiling (auto-worktree.sh).
# Sets the globals PD_WORKTREE + PD_BRANCH (it is called DIRECTLY, not in $(), so a
# kill_check inside any phase can `exit` the whole process — command substitution
# would trap the exit in a subshell). Returns 0 / EX_CONCURRENCY / EX_ERR.
# =========================================================================== #
PD_WORKTREE=""
PD_BRANCH=""
phase_d_branch() {
  local issue="$1" issue_json="$2"
  export AUTO_PHASE="branch"
  PD_WORKTREE=""; PD_BRANCH=""

  local btype title branch
  btype="$(branch_type_from_labels "$issue_json")"
  title="$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null || true)"
  branch="$(git_branch_name "$btype" "$issue" "$title")"
  PD_BRANCH="$branch"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    # Dry-run: compute the branch name + intended worktree path; create NOTHING.
    PD_WORKTREE="$(git_worktree_path "$issue")"
    log_info "iter_branch_dry" "DRY-RUN: would create worktree for issue=${issue} branch=${branch} at ${PD_WORKTREE}"
    return 0
  fi

  local path
  set +e
  path="$("${_SELF_DIR}/auto-worktree.sh" add \
            --issue "$issue" --type "$btype" --title "$title" \
            --concurrency "$CONCURRENCY" ${REPO:+--repo "$REPO"})"
  local wrc=$?
  set -e
  if [[ "$wrc" -eq "$EX_CONCURRENCY" ]]; then
    log_info "iter_branch_concurrency" "worktree ceiling reached for issue=${issue}"
    return "$EX_CONCURRENCY"
  elif [[ "$wrc" -ne 0 || -z "$path" ]]; then
    log_error "iter_branch_err" "worktree-add-failed" "issue=${issue} branch=${branch} rc=${wrc}"
    return "$EX_ERR"
  fi
  # auto-worktree.sh prints log lines too; the worktree path is the LAST stdout line.
  PD_WORKTREE="$(printf '%s' "$path" | tail -n1)"
  log_info "iter_branch_ok" "issue=${issue} branch=${branch} worktree=${PD_WORKTREE}"
  return 0
}

# =========================================================================== #
# PHASE E — EXECUTE is performed by the /auto SESSION, not this script.
#
# In the session-spine model the live Claude Code session runs EXECUTE: it routes by
# size (SKILL.md §4.3), spawns the `auto:<role>` subagents via the Agent tool (flat,
# depth-1), runs the bounded review rounds, and commits each accepted change through
# `commit-gate.sh`. A shell script cannot spawn in-session subagents, so EXECUTE lives
# BETWEEN `--phase prep` (which hands the session the issue + worktree + branch with a
# live claim) and `--phase finish` (which pushes, opens the base-locked PR, and merges
# when green). This script owns only the deterministic, mutating phases; the cognitive
# phase is the session's. Escalation (rounds exhausted / XL split) is likewise the
# session's decision, executed via `auto-release.sh --outcome hard`.
# =========================================================================== #

# =========================================================================== #
# PHASE F — PR. Push the head branch + open the base-locked PR (auto-pr-create.sh).
# The engine already committed through commit-gate.sh per commit; here we only push
# and open the PR. KILL-CHECK POINTS 4 (before push) and 5 (before PR open).
# Sets the global WORK_PR (the PR number, or "-" under dry-run). Called DIRECTLY (not
# in $()) so the kill_checks here can `exit` the whole process. Returns 0 / the exact
# PR exit code (70/71/72/...) / EX_ERR.
# =========================================================================== #
phase_f_pr() {
  local issue="$1" issue_json="$2" worktree="$3" branch="$4"
  export AUTO_PHASE="pr"

  # KILL-CHECK 4 — before commit/push.
  kill_check "before-push"

  # Confirm there is something to ship (at least one commit beyond the base tip).
  git_fetch_base || true
  local base_tip ahead
  base_tip="$(git_base_tip 2>/dev/null || true)"
  ahead="$(git -C "$worktree" rev-list --count "${base_tip:-origin/${AUTO_BASE_BRANCH}}..HEAD" 2>/dev/null || echo 0)"
  if [[ "${ahead:-0}" -eq 0 ]]; then
    log_info "iter_pr_nochange" "issue=${issue} no commits ahead of ${AUTO_BASE_BRANCH}; nothing to PR"
    return "$EX_ERR"
  fi

  local title body_file
  title="$(printf '%s' "$issue_json" | jq -r '.title // ("issue " + (.number|tostring))' 2>/dev/null || echo "issue ${issue}")"
  # PR body MUST contain `Closes #N` (closes the issue on merge) + run/runner context.
  body_file="$(mktemp -t auto-pr-body.XXXXXX)"
  {
    printf 'Closes #%s\n\n' "$issue"
    printf 'Automated change by `/auto` (run `%s`, runner `%s`).\n' "$RUN_ID" "$RUNNER_ID"
    printf 'Base is hard-locked to `%s`; squash-merged when CI is 100%% green.\n' "$AUTO_BASE_BRANCH"
  } > "$body_file"

  # Carry the issue's type:* + size:* + priority:* labels onto the PR for visibility.
  local label_args=() lbl
  for lbl in $(printf '%s' "$issue_json" | jq -r '.labels[].name | select(test("^(type:|size:|priority:)"))' 2>/dev/null || true); do
    label_args+=(--label "$lbl")
  done

  # KILL-CHECK 5 — before opening the PR.
  kill_check "before-pr"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "iter_pr_dry" "DRY-RUN: would push ${branch} and open PR (base=${AUTO_BASE_BRANCH}, title='${title}') ${label_args[*]:-}"
    rm -f "$body_file" 2>/dev/null || true
    WORK_PR="-"
    return 0
  fi

  local pr
  set +e
  pr="$("${_SELF_DIR}/auto-pr-create.sh" \
          --head "$branch" --issue "$issue" --title "$title" \
          --body-file "$body_file" --dir "$worktree" \
          "${label_args[@]+"${label_args[@]}"}")"
  local prc=$?
  set -e
  rm -f "$body_file" 2>/dev/null || true

  if [[ "$prc" -ne 0 ]]; then
    log_error "iter_pr_err" "pr-create-rc-${prc}" "issue=${issue} branch=${branch}"
    return "$prc"   # propagate the exact PR exit code (70/71/72/...) to the caller.
  fi
  pr="$(printf '%s' "$pr" | tail -n1)"
  [[ "$pr" =~ ^[0-9]+$ ]] || { log_error "iter_pr_parse" "no-pr-number" "got '${pr}'"; return "$EX_ERR"; }
  WORK_PR="$pr"
  log_info "iter_pr_ok" "issue=${issue} PR #${pr} open against ${AUTO_BASE_BRANCH}"
  return 0
}

# =========================================================================== #
# PHASE G — MERGE / RELEASE. Drive the PR to a green squash-merge
# (auto-merge-when-green.sh). The claim was ALREADY released as `success` (the issue
# sits in status:in-review, owned by the open PR) BEFORE this phase, so the issue is
# crash-safe: a kill -9 mid-merge leaves it resumable in-review, never orphaned.
#
# On merge SUCCESS the issue is closed by the PR's `Closes #N`; we finalize the
# lifecycle label and GC the worktree. On a TERMINAL merge failure (green-floor /
# not-green / conflict) auto-merge-when-green.sh itself escalates: it labels the PR
# status:blocked, comments, and invokes the injected --escalate-cmd hook, which files
# the human-gated follow-up + blocks the issue via auto-release.sh (escalation is thus
# centralized in the single release path). A transient merge failure leaves the issue
# in status:in-review for a later iteration / human to resume.
# =========================================================================== #
phase_g_merge() {
  local issue="$1" pr="$2" worktree="$3"
  export AUTO_PHASE="merge"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "iter_merge_dry" "DRY-RUN: would auto-merge-when-green PR #${pr:--} for issue=${issue}"
    return 0
  fi

  # Escalate hook (terminal-failure path only): re-route the issue to a HARD release
  # (files the human-gated follow-up + marks the original status:blocked). The PR is
  # already labelled status:blocked by the merge script before this hook runs.
  local esc_hook
  esc_hook="${_SELF_DIR}/auto-release.sh ${issue} hard-merge --outcome hard --runner ${RUNNER_ID}${pr:+ --pr ${pr}}"

  set +e
  "${_SELF_DIR}/auto-merge-when-green.sh" \
    --pr "$pr" --issue "$issue" --dir "$worktree" \
    --escalate-cmd "$esc_hook" >/dev/null 2>&1
  local mrc=$?
  set -e

  case "$mrc" in
    0)
      # Merged. `Closes #N` closes the issue; finalize the lifecycle label + GC worktree
      # (the auto/* head branch was deleted by gh pr merge --delete-branch).
      log_info "iter_merged" "issue=${issue} PR #${pr} squash-merged into ${AUTO_BASE_BRANCH}"
      gh_issue_add_labels "$issue" "$AUTO_LABEL_STATUS_DONE" >/dev/null 2>&1 || true
      gh_issue_remove_labels "$issue" "$AUTO_LABEL_STATUS_IN_REVIEW" >/dev/null 2>&1 || true
      # Close the issue EXPLICITLY: a "Closes #N" in the PR body auto-closes only on a
      # merge to the repo's DEFAULT branch, never on a merge to develop-auto — so the
      # engine must close it itself (else issues pile up OPEN+status:done forever).
      gh_retry gh.issue_close -- issue close "$issue" --reason completed >/dev/null 2>&1 || true
      remove_worktree
      return 0 ;;
    "$EX_PR_GREEN_FLOOR"|"$EX_PR_NOT_GREEN"|"$EX_PR_CONFLICT")
      # auto-merge-when-green.sh already escalated (PR labelled + --escalate-cmd hook ran
      # the hard release). Just GC the worktree and propagate the exact code.
      log_error "iter_merge_blocked" "merge-rc-${mrc}" "issue=${issue} PR #${pr} escalated; not merged"
      remove_worktree
      return "$mrc" ;;
    "$EX_PR_VERIFY")
      # Base drifted at merge time. The merge script does NOT run the escalate hook for
      # this case (it exits 72 directly), so escalate it HERE: file the human-gated
      # follow-up + block the issue. The success-release already moved it to in-review;
      # auto-release.sh is additive/idempotent, so the hard release re-blocks it cleanly.
      log_error "iter_merge_basedrift" "base-drift" "issue=${issue} PR #${pr} base drifted from ${AUTO_BASE_BRANCH}"
      RELEASED=0; release_claim "hard-base-drift" "hard"
      remove_worktree
      return "$EX_PR_VERIFY" ;;
    "$EX_PREFLIGHT_ACCOUNT")
      log_error "iter_merge_account" "account" "merge failed: wrong gh account"
      return "$EX_PREFLIGHT_ACCOUNT" ;;
    *)
      # Transient merge poll failure: the PR is open + the issue is in status:in-review.
      # Leave it for a later resume (do NOT re-queue / re-block). Not a halt-worthy error.
      log_error "iter_merge_transient" "merge-rc-${mrc}" "issue=${issue} PR #${pr}; left in-review for resume"
      return "$EX_ERR" ;;
  esac
}

# =========================================================================== #
# run_prep — A cold-boot → B/C select+claim (or resume) → D branch. Emits ONE PREP
# line and leaves the claim LIVE so the session can run EXECUTE then `--phase finish`.
#   PREP issue=<N|-> size=<S|M|L|XL|-> branch=<name|-> worktree=<path|-> reason=<token>
# =========================================================================== #
emit_prep() {
  printf 'PREP issue=%s size=%s branch=%s worktree=%s reason=%s\n' \
    "${1:--}" "${2:--}" "${3:--}" "${4:--}" "${5:-ok}"
}

run_prep() {
  # --- A: cold-boot (account pin + KILL POINT 1 + prune + locate control). -----
  phase_a_coldboot

  # --- B/C: select + claim (or resume). ----------------------------------------
  set +e
  SELECTED="$(select_resume_issue)"
  local sel_rc=$?
  set -e
  case "$sel_rc" in
    0) : ;;
    "$EX_CONCURRENCY")       emit_prep "" "" "" "" "concurrency";   log_info "iter_end" "result=concurrency"; exit "$EX_CONCURRENCY" ;;
    "$EX_CLAIM_LOST")        emit_prep "" "" "" "" "claim-lost";    log_info "iter_end" "result=claim-lost"; exit "$EX_CLAIM_LOST" ;;
    "$EX_NOT_CLAIMABLE")     emit_prep "" "" "" "" "not-claimable"; log_info "iter_end" "result=no-work"; exit "$EX_OK" ;;
    "$EX_PREFLIGHT_ACCOUNT") emit_prep "" "" "" "" "account";       log_error "iter_end" "account" "pin failed"; exit "$EX_PREFLIGHT_ACCOUNT" ;;
    *)                       emit_prep "" "" "" "" "select-error";  log_error "iter_end" "select-error" "rc=${sel_rc}"; exit "$EX_ERR" ;;
  esac

  if [[ -z "$SELECTED" ]]; then
    # No eligible work and no resumable issue — a clean no-op (the gate decides whether
    # to idle-backoff or stop; constants.sh AUTO_STOP_REASON_BACKLOG).
    emit_prep "" "" "" "" "backlog-empty"
    log_info "iter_end" "result=no-work reason=backlog-empty"
    exit "$EX_OK"
  fi

  ISSUE="$SELECTED"
  export AUTO_ISSUE="$ISSUE"
  # select_resume_issue ran in a command substitution (subshell), so its CLAIMED_ISSUE
  # did not persist to this shell. Re-establish it (the claim genuinely happened) so the
  # release trap + PREP line work.
  CLAIMED_ISSUE="$ISSUE"

  # KILL-CHECK 2 — just after claim (state-model §4.2 point 2).
  kill_check "after-claim"

  # Re-read the claimed issue's full JSON for size + branch metadata. Cold-safe.
  ISSUE_JSON="$(gh_issue_view "$ISSUE" "number,title,body,labels,state,url" 2>/dev/null || echo '{}')"
  if [[ "$(printf '%s' "$ISSUE_JSON" | jq -r '.number // empty' 2>/dev/null || true)" != "$ISSUE" ]]; then
    log_error "iter_issue_read" "issue-read-failed" "issue=${ISSUE}"
    release_claim "recoverable-read-fail" "recoverable"
    emit_prep "$ISSUE" "" "" "" "issue-read-failed"
    exit "$EX_ERR"
  fi
  local size; size="$(size_from_labels "$ISSUE_JSON")"

  # --- D: branch / worktree from develop-auto. ---------------------------------
  set +e
  phase_d_branch "$ISSUE" "$ISSUE_JSON"
  local brc=$?
  set -e
  if [[ "$brc" -eq "$EX_CONCURRENCY" ]]; then
    release_claim "recoverable-concurrency" "recoverable"
    emit_prep "$ISSUE" "$size" "" "" "concurrency"
    exit "$EX_CONCURRENCY"
  elif [[ "$brc" -ne 0 ]]; then
    release_claim "recoverable-branch-fail" "recoverable"
    emit_prep "$ISSUE" "$size" "" "" "branch-failed"
    exit "$EX_ERR"
  fi

  # SUCCESS. The claim must PERSIST so the session can run EXECUTE and then call
  # `--phase finish` with the SAME AUTO_RUNNER_ID. Suppress the EXIT-trap release for
  # this clean hand-off (RELEASED=1 makes release_claim + on_exit no-ops).
  RELEASED=1
  emit_prep "$ISSUE" "$size" "$PD_BRANCH" "$PD_WORKTREE" "ok"
  log_info "iter_end" "result=prep issue=${ISSUE} size=${size} branch=${PD_BRANCH} worktree=${PD_WORKTREE}"
  exit "$EX_OK"
}

# =========================================================================== #
# run_finish — given an issue the session just ran EXECUTE on (in --worktree): F push
# + base-locked PR → G green squash-merge → release. Emits the ITER terminal line.
# Re-establishes the claim context using the SAME AUTO_RUNNER_ID the session passed to
# `--phase prep` (so the lease release matches). Kill-checks 4/5 are inside phase_f_pr.
# =========================================================================== #
run_finish() {
  [[ -n "$ARG_ISSUE" ]]       || { log_error "iter_args" "finish-no-issue" "--phase finish requires --issue"; exit "$EX_ERR"; }
  [[ -n "$FINISH_WORKTREE" ]] || { log_error "iter_args" "finish-no-worktree" "--phase finish requires --worktree"; exit "$EX_ERR"; }

  CLAIMED_ISSUE="$ARG_ISSUE"
  export AUTO_ISSUE="$CLAIMED_ISSUE"

  # finish mutates (push/PR/merge): resolve the run identity, then kill-check before any work.
  if ! gh_select_account >/dev/null; then
    log_error "iter_account" "account-resolve-failed" "could not resolve/assert the active gh account"
    emit_and_exit "error" "$EX_PREFLIGHT_ACCOUNT" "account"
  fi
  kill_check "finish-top"

  local issue_json
  issue_json="$(gh_issue_view "$CLAIMED_ISSUE" "number,title,body,labels,state,url" 2>/dev/null || echo '{}')"
  if [[ "$(printf '%s' "$issue_json" | jq -r '.number // empty' 2>/dev/null || true)" != "$CLAIMED_ISSUE" ]]; then
    log_error "iter_issue_read" "issue-read-failed" "issue=${CLAIMED_ISSUE}"
    release_claim "recoverable-read-fail" "recoverable"
    emit_and_exit "error" "$EX_ERR" "issue-read"
  fi

  local worktree="$FINISH_WORKTREE" branch="$FINISH_BRANCH"
  if [[ -z "$branch" ]]; then
    branch="$(git_branch_name "$(branch_type_from_labels "$issue_json")" "$CLAIMED_ISSUE" \
              "$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null || true)")"
  fi

  # --- F: push + base-locked PR (kill-checks 4/5 inside; sets global WORK_PR). --
  set +e
  phase_f_pr "$CLAIMED_ISSUE" "$issue_json" "$worktree" "$branch"
  local frc=$?
  set -e
  if [[ "$frc" -ne 0 ]]; then
    case "$frc" in
      "$EX_PR_BASE_LOCK"|"$EX_PR_VERIFY")
        release_claim "hard-pr-${frc}" "hard"
        emit_and_exit "escalated" "$frc" "pr-base-lock" ;;
      "$EX_PR_PUSH")
        release_claim "recoverable-push-fail" "recoverable"
        emit_and_exit "error" "$EX_PR_PUSH" "push" ;;
      *)
        release_claim "recoverable-pr-fail" "recoverable"
        emit_and_exit "error" "$EX_ERR" "pr" ;;
    esac
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "iter_dryrun_ok" "DRY-RUN complete for issue=${CLAIMED_ISSUE}: would PR + auto-merge"
    emit_and_exit "dry-run" "$EX_OK" "dry-run"
  fi

  local pr="$WORK_PR"

  # Record the PR-open `success` release BEFORE the merge poll, so a crash mid-merge
  # leaves the issue safely in status:in-review (not re-queued, not orphaned). Sets
  # RELEASED=1; the merge phase only files a hard escalation on terminal failure.
  release_claim "pr-open" "success"

  # --- G: drive PR to green squash-merge, then close/escalate. -----------------
  set +e
  phase_g_merge "$CLAIMED_ISSUE" "$pr" "$worktree"
  local grc=$?
  set -e
  case "$grc" in
    0)                    emit_and_exit "merged" "$EX_OK" "merged" ;;
    "$EX_PR_GREEN_FLOOR") emit_and_exit "escalated" "$EX_PR_GREEN_FLOOR" "green-floor" ;;
    "$EX_PR_NOT_GREEN")   emit_and_exit "escalated" "$EX_PR_NOT_GREEN" "not-green" ;;
    "$EX_PR_CONFLICT")    emit_and_exit "escalated" "$EX_PR_CONFLICT" "conflict" ;;
    "$EX_PR_VERIFY")      emit_and_exit "escalated" "$EX_PR_VERIFY" "base-drift" ;;
    *)                    emit_and_exit "pr-open" "$EX_OK" "pr-open-merge-pending" ;;
  esac
}

# =========================================================================== #
# MAIN — dispatch on --phase. EXECUTE (the cognitive phase between prep and finish)
# is the /auto SESSION's job (it spawns the auto:<role> subagents); see SKILL.md §4.
# =========================================================================== #
case "$PHASE" in
  prep)   run_prep ;;
  finish) run_finish ;;
  *) log_error "iter_args" "bad-phase" "--phase must be prep|finish (got '${PHASE}')"; exit "$EX_ERR" ;;
esac
