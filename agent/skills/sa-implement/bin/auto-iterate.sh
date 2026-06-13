#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-iterate.sh — the deterministic FINISH phase of one sa-implement iteration.
#
# The git+gh engine spine (never the GitHub MCP). In the daemon-orchestrated model the
# agent session does the cognitive EXECUTE (claim + worktree are taken via auto-api.sh's
# `prep` verb = auto-claim.sh + auto-worktree.sh), then hands the finished issue here:
#
#   --phase finish (F→G): push → base-locked PR (auto-pr-create.sh) → green squash-merge
#                 (auto-merge-when-green.sh) → release. Prints one ITER line.
#
# Phases:
#   F  PR            push → auto-pr-create.sh (base-locked + verified).
#   G  MERGE/RELEASE auto-merge-when-green.sh → close/escalate; always release the claim.
#
# Crash-safe: an EXIT/INT/TERM trap releases the claim (auto-release.sh) even on crash.
# The PR-open `success` release is recorded BEFORE the merge poll, so a kill -9 mid-merge
# leaves the issue resumable in status:in-review, never orphaned. The kill-switch
# (auto-kill.sh) is checked at the documented points. Runner identity is shared with the
# prep that claimed the issue via a caller-passed AUTO_RUNNER_ID (so finish releases the
# lease prep took).
#
# Usage:
#   auto-iterate.sh --phase finish --issue <N> --worktree <path> [--branch <name>]
#                                  [--control <issue#>] [--run-id <id>]
#                                  [--repo <owner/repo>] [--verbose]
#   (Export the same AUTO_RUNNER_ID the prep used.)
#
# Stdout (exactly one machine-parseable terminal line):
#   ITER <result> issue=<N|-> pr=<N|-> reason=<token>
#     result ∈ {merged, pr-open, escalated, error}
#
# Exit codes (constants.sh §10 — the caller routes on these):
#   0   progress (merged / pr-open).
#   2   kill-switch engaged at a check-point (clean stop).
#   69  gh account could not be resolved/asserted.
#   70-75 PR/merge failures (base-lock / push / verify / not-green / green-floor /
#       conflict) — surfaced after best-effort escalation.
#   1   generic / argument error.
#
# Depends ONLY on: git, gh, jq (+ gitleaks via commit-gate.sh upstream). Sources
# constants/log/gh/git; shells out to the sibling bin/*.sh by their documented contracts.
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

export AUTO_PHASE="iterate"

# =========================================================================== #
# Args.
# =========================================================================== #
ARG_ISSUE=""
CONTROL_ISSUE=""
RUN_ID="${AUTO_RUN_ID:-}"
PHASE="finish"           # finish (F-G: PR+merge+release) is the only phase.
FINISH_WORKTREE=""       # the worktree the session ran EXECUTE in.
FINISH_BRANCH=""         # the head branch (else re-derived from labels).
REPO=""

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)       ARG_ISSUE="${2:?--issue requires a number}"; shift 2 ;;
    --phase)       PHASE="${2:?--phase requires finish}"; shift 2 ;;
    --control)     CONTROL_ISSUE="${2:?--control requires an issue#}"; shift 2 ;;
    --run-id)      RUN_ID="${2:?--run-id requires a value}"; shift 2 ;;
    --worktree)    FINISH_WORKTREE="${2:?--worktree requires a path}"; shift 2 ;;
    --branch)      FINISH_BRANCH="${2:?--branch requires a name}"; shift 2 ;;
    --repo)        REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --verbose)     AUTO_VERBOSE=1; export AUTO_VERBOSE; shift ;;
    -h|--help)     print_help ;;
    *) log_error "iter_args" "unknown-arg" "unknown argument: $1"; exit "$EX_ERR" ;;
  esac
done

if [[ -n "$ARG_ISSUE" && ! "$ARG_ISSUE" =~ ^[0-9]+$ ]]; then
  log_error "iter_args" "bad-issue" "--issue must be a number: $ARG_ISSUE"; exit "$EX_ERR"
fi

[[ -n "$RUN_ID" ]] || RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
export AUTO_RUN_ID="$RUN_ID"

# Thread --repo to every gh.sh wrapper (they read GH_REPO; they have no --repo param).
[[ -n "$REPO" ]] && export GH_REPO="$REPO"

# Stable runner identity so claim (prep) + release (here) + lease share one id
# (auto-release.sh honours a pre-exported AUTO_RUNNER_ID).
if [[ -z "${AUTO_RUNNER_ID:-}" ]]; then
  AUTO_RUNNER_ID="${AUTO_RUNNER_PREFIX}-$(hostname -s 2>/dev/null || echo host)-$$-$(date +%s)-${RANDOM}"
fi
export AUTO_RUNNER_ID
readonly RUNNER_ID="$AUTO_RUNNER_ID"

log_info "iter_begin" "run=${RUN_ID} phase=${PHASE} runner=${RUNNER_ID}${ARG_ISSUE:+ issue=${ARG_ISSUE}}"

# =========================================================================== #
# Terminal-result emission + claim-release trap (crash-safe; decisions.md §4).
# =========================================================================== #
CLAIMED_ISSUE=""          # set once we hold a claim; the trap releases it.
RELEASED=0                # set once a release (success/recoverable/hard) has run.
WORK_PR=""                # set once a PR is open/created for the issue.
ITER_REASON="-"           # last reason token (default for emit_and_exit's reason arg).

# emit_and_exit <result> <exit-code> [reason]
emit_and_exit() {
  local result="$1" code="$2" reason="${3:-$ITER_REASON}"
  ITER_REASON="$reason"
  printf 'ITER %s issue=%s pr=%s reason=%s\n' \
    "$result" "${CLAIMED_ISSUE:--}" "${WORK_PR:--}" "$reason"
  log_info "iter_end" "result=${result} issue=${CLAIMED_ISSUE:--} pr=${WORK_PR:--} reason=${reason} code=${code}"
  exit "$code"
}

# release_claim <reason> [outcome] — the single sanctioned release path. Idempotent.
release_claim() {
  local reason="$1" outcome="${2:-}"
  [[ -z "$CLAIMED_ISSUE" || "$RELEASED" == 1 ]] && return 0
  RELEASED=1
  local args=("$CLAIMED_ISSUE" "$reason" --runner "$RUNNER_ID")
  [[ -n "$outcome" ]] && args+=(--outcome "$outcome")
  [[ -n "$WORK_PR" ]] && args+=(--pr "$WORK_PR")
  set +e
  "${_SELF_DIR}/auto-release.sh" "${args[@]}" >/dev/null 2>&1
  local rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || log_error "iter_release" "release-nonzero" "auto-release.sh rc=${rc} issue=${CLAIMED_ISSUE}"
}

# remove_worktree — best-effort cleanup. A pushed branch backing an open PR is preserved
# by auto-worktree.sh's default PR-check.
remove_worktree() {
  [[ -z "$CLAIMED_ISSUE" ]] && return 0
  set +e
  "${_SELF_DIR}/auto-worktree.sh" remove --issue "$CLAIMED_ISSUE" ${REPO:+--repo "$REPO"} >/dev/null 2>&1
  set -e
}

# on_exit — crash-safe net: release an un-released claim as RECOVERABLE so work is never
# orphaned in auto:claimed (auto-release.sh "fail-safe default = recoverable").
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
# kill_check <point> — the SINGLE canonical kill-switch check (auto-kill.sh; exit 0 ==
# KILLED). On a kill: release any claim (cooperative) and exit cleanly with
# EX_PREFLIGHT_KILLSWITCH (2 — a clean stop, not an error).
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

# branch_type_from_labels <issue-json> -> branch <type> token (conventions §1).
#   type:feature→feat, type:bug→fix, others map 1:1. Default chore.
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

# =========================================================================== #
# PHASE F — PR. Push the head branch + open the base-locked PR (auto-pr-create.sh).
# The engine already committed through commit-gate.sh per commit; here we only push and
# open the PR. KILL-CHECK before push and before PR open. Sets the global WORK_PR. Called
# DIRECTLY (not in $()) so the kill_checks here can `exit` the whole process. Returns
# 0 / the exact PR exit code (70/71/72/...) / EX_ERR.
# =========================================================================== #
phase_f_pr() {
  local issue="$1" issue_json="$2" worktree="$3" branch="$4"
  export AUTO_PHASE="pr"

  # KILL-CHECK — before commit/push.
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
    printf 'Automated change by `sa-implement` (run `%s`, runner `%s`).\n' "$RUN_ID" "$RUNNER_ID"
    printf 'Base is hard-locked to `%s`; squash-merged when CI is 100%% green.\n' "$AUTO_BASE_BRANCH"
  } > "$body_file"

  # Carry the issue's type:* + size:* + priority:* labels onto the PR for visibility.
  local label_args=() lbl
  for lbl in $(printf '%s' "$issue_json" | jq -r '.labels[].name | select(test("^(type:|size:|priority:)"))' 2>/dev/null || true); do
    label_args+=(--label "$lbl")
  done

  # KILL-CHECK — before opening the PR.
  kill_check "before-pr"

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
# sits in status:in-review, owned by the open PR) BEFORE this phase, so a kill -9
# mid-merge leaves it resumable in-review, never orphaned. On a TERMINAL merge failure
# the merge script escalates via the injected --escalate-cmd hook (files the human-gated
# follow-up + blocks the issue via auto-release.sh).
# =========================================================================== #
phase_g_merge() {
  local issue="$1" pr="$2" worktree="$3"
  export AUTO_PHASE="merge"

  # Escalate hook (terminal-failure path only): re-route the issue to a HARD release
  # (files the human-gated follow-up + marks the original status:blocked).
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
      log_info "iter_merged" "issue=${issue} PR #${pr} squash-merged into ${AUTO_BASE_BRANCH}"
      gh_issue_add_labels "$issue" "$AUTO_LABEL_STATUS_DONE" >/dev/null 2>&1 || true
      gh_issue_remove_labels "$issue" "$AUTO_LABEL_STATUS_IN_REVIEW" >/dev/null 2>&1 || true
      # Close the issue EXPLICITLY: a "Closes #N" in the PR body auto-closes only on a
      # merge to the repo's DEFAULT branch, never on a merge to develop-auto.
      gh_retry gh.issue_close -- issue close "$issue" --reason completed >/dev/null 2>&1 || true
      remove_worktree
      return 0 ;;
    "$EX_PR_GREEN_FLOOR"|"$EX_PR_NOT_GREEN"|"$EX_PR_CONFLICT")
      log_error "iter_merge_blocked" "merge-rc-${mrc}" "issue=${issue} PR #${pr} escalated; not merged"
      remove_worktree
      return "$mrc" ;;
    "$EX_PR_VERIFY")
      # Base drifted at merge time; the merge script exits 72 WITHOUT running the hook,
      # so escalate HERE (auto-release.sh is additive/idempotent, re-blocks cleanly).
      log_error "iter_merge_basedrift" "base-drift" "issue=${issue} PR #${pr} base drifted from ${AUTO_BASE_BRANCH}"
      RELEASED=0; release_claim "hard-base-drift" "hard"
      remove_worktree
      return "$EX_PR_VERIFY" ;;
    "$EX_PREFLIGHT_ACCOUNT")
      log_error "iter_merge_account" "account" "merge failed: wrong gh account"
      return "$EX_PREFLIGHT_ACCOUNT" ;;
    *)
      # Transient merge poll failure: PR open + issue in status:in-review. Leave for a
      # later resume (do NOT re-queue / re-block).
      log_error "iter_merge_transient" "merge-rc-${mrc}" "issue=${issue} PR #${pr}; left in-review for resume"
      return "$EX_ERR" ;;
  esac
}

# =========================================================================== #
# run_finish — given an issue the session ran EXECUTE on (in --worktree): F push +
# base-locked PR → G green squash-merge → release. Emits the ITER terminal line. Uses
# the SAME AUTO_RUNNER_ID the prep used (so the lease release matches).
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

  # --- F: push + base-locked PR (kill-checks inside; sets global WORK_PR). ------
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

  local pr="$WORK_PR"

  # Record the PR-open `success` release BEFORE the merge poll, so a crash mid-merge
  # leaves the issue safely in status:in-review. Sets RELEASED=1.
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
# MAIN — finish is the only phase (prep is the daemon/auto-api `prep` verb now).
# =========================================================================== #
case "$PHASE" in
  finish) run_finish ;;
  *) log_error "iter_args" "bad-phase" "--phase must be finish (got '${PHASE}'); prep is now auto-api.sh prep"; exit "$EX_ERR" ;;
esac
