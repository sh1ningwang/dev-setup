#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-merge-when-green.sh — poll a PR's required checks and squash-merge it into
# develop-auto ONLY when CI is 100% green (decisions.md D3).
#
# Hard rules enforced here:
#   * GREEN FLOOR (D3 / architecture §2.3): if the develop-auto required-check set
#     is EMPTY, REFUSE to merge -> exit 74. A misconfigured repo must never ship
#     unverified code.
#   * Local poll-then-merge (NOT platform `--auto`): poll
#     `gh pr checks --required` (exit 8 = pending) until green / timeout.
#   * Bounded flaky reruns: re-run ONLY failed required checks up to FLAKY_RETRY_MAX,
#     then escalate (never merge red).
#   * Conflicts: `gh pr update-branch` (merge-from-base) ONLY. NO force-push, ever
#     (decisions.md §2; AUTO_ALLOW_FORCE_PUSH=0). Unresolvable -> exit 75.
#   * Merge: squash, subject = PR title, body SCRUBBED to empty (no Co-Authored-By
#     can survive the squash even if an upstream CLI injected one; HC6).
#   * Base is re-asserted every poll; drift -> exit 72.
#
# Escalation (exhaustion / timeout / conflict / red): best-effort labels the PR
# status:blocked, posts a summary comment, and (if --escalate-cmd is given) invokes
# the injected escalation hook. Then exits with the matching non-zero code so the
# driver can route it (decisions.md §6).
#
# Usage:
#   auto-merge-when-green.sh --pr <N> [--issue <N>] [--dir <path>]
#                            [--escalate-cmd "<cmd>"]
#   --pr <N>             the PR number to drive to merge.
#   --issue <N>          originating issue (logging/escalation context).
#   --dir <path>         repo/worktree dir (default: AUTO_ROOT, else cwd).
#   --escalate-cmd "..." command invoked on terminal failure; receives args:
#                        <pr#> <reason>. Reason in: ci-failure|ci-timeout|conflict.
#
# Exit codes (decisions.md §6):
#   0   merged (squash) into develop-auto.
#   69  gh account could not be resolved, or drifted from the run identity.
#   72  base drifted away from develop-auto.
#   73  required checks not green (failed after flaky budget) OR PR not open OR
#       poll timeout — escalated, not merged.
#   74  GREEN FLOOR: develop-auto required-check set is empty -> refuse to merge.
#   75  merge conflict could not be resolved without force-push.
#   1   generic / argument error.
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_SELF_DIR}/../lib/constants.sh"
# shellcheck source=../lib/log.sh
source "${_SELF_DIR}/../lib/log.sh"
# shellcheck source=../lib/gh.sh
source "${_SELF_DIR}/../lib/gh.sh"
# shellcheck source=../lib/git.sh
source "${_SELF_DIR}/../lib/git.sh"

export AUTO_PHASE="${AUTO_PHASE:-merge}"

# Print the leading header comment block (top-of-file usage) and exit 0.
print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
PR_NUM=""
ISSUE=""
WORK_DIR="${AUTO_ROOT:-$(pwd)}"
ESCALATE_CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)           PR_NUM="${2:?--pr requires a number}"; shift 2 ;;
    --issue)        ISSUE="${2:?--issue requires a number}"; shift 2 ;;
    --dir)          WORK_DIR="${2:?--dir requires a path}"; shift 2 ;;
    --escalate-cmd) ESCALATE_CMD="${2?--escalate-cmd requires a command}"; shift 2 ;;
    -h|--help) print_help ;;
    *)
      log_error "merge_args" "unknown-arg" "unknown argument: $1"
      exit "$EX_ERR" ;;
  esac
done

[[ -n "$PR_NUM" ]] || { log_error "merge_args" "no-pr" "--pr is required"; exit "$EX_ERR"; }
[[ -d "$WORK_DIR" ]] || { log_error "merge_dir" "missing-dir" "work dir does not exist: $WORK_DIR"; exit "$EX_ERR"; }
[[ -n "$ISSUE" ]] && export AUTO_ISSUE="$ISSUE"
cd "$WORK_DIR"

# --------------------------------------------------------------------------- #
# Account resolution. Delegate to the single sanctioned chokepoint
# in gh.sh: it resolves the ACTIVE local gh login (never switches), HARD-ASSERTS via
# `gh api user` that it has not drifted, and ensures a git author identity itself.
# --------------------------------------------------------------------------- #
gh_select_account >/dev/null || exit "$EX_PREFLIGHT_ACCOUNT"

# --------------------------------------------------------------------------- #
# escalate <reason>
#   Best-effort: label the PR status:blocked, comment a summary, invoke the
#   injected --escalate-cmd hook (if any). Human-gated follow-up issue creation is
#   the hook's responsibility (it owns auto:hold + status:triage; decisions.md §3).
# --------------------------------------------------------------------------- #
escalate() {
  local reason="$1"
  log_error "merge_escalate" "$reason" "escalating PR #${PR_NUM} (reason=${reason}); not merging"
  gh_retry gh.merge_escalate_label -- pr edit "$PR_NUM" --add-label "$AUTO_LABEL_STATUS_BLOCKED" >/dev/null 2>&1 \
    || log_info "merge_escalate_label_warn" "WARN: could not add ${AUTO_LABEL_STATUS_BLOCKED} to PR #${PR_NUM}"
  gh_retry gh.merge_escalate_comment -- pr comment "$PR_NUM" \
    --body "auto-merge halted: ${reason}. Required checks did not reach a clean green state within policy; a human must intervene. (No force-push performed.)" \
    >/dev/null 2>&1 || log_info "merge_escalate_comment_warn" "WARN: could not comment on PR #${PR_NUM}"
  if [[ -n "$ESCALATE_CMD" ]]; then
    log_info "merge_escalate_hook" "invoking escalate hook for PR #${PR_NUM}"
    # shellcheck disable=SC2086
    bash -c "$ESCALATE_CMD" _ "$PR_NUM" "$reason" \
      || log_error "merge_escalate_hook_fail" "hook-error" "escalate hook returned non-zero"
  fi
}

# --------------------------------------------------------------------------- #
# GREEN FLOOR (decisions.md D3 / A7'): the authoritative required-check set on
# develop-auto must be NON-EMPTY. The union of classic branch protection +
# rulesets is computed in gh.sh (gh_required_check_count / gh_green_floor_ok),
# which both honor AUTO_GREEN_FLOOR — never re-derived here.
# --------------------------------------------------------------------------- #
if ! gh_green_floor_ok "$AUTO_BASE_BRANCH"; then
  log_error "merge_green_floor" "empty-required-set" \
    "GREEN FLOOR: ${AUTO_BASE_BRANCH} has an EMPTY required-check set; refusing to merge unverified code"
  escalate "green-floor-empty-checks"
  exit "$EX_PR_GREEN_FLOOR"
fi
REQ_COUNT="$(gh_required_check_count "$AUTO_BASE_BRANCH" 2>/dev/null || echo '?')"
log_info "merge_green_floor_ok" "${AUTO_BASE_BRANCH} has ${REQ_COUNT} required check(s)"

# --------------------------------------------------------------------------- #
# Poll loop.
# --------------------------------------------------------------------------- #
DEADLINE=$(( $(date +%s) + CHECK_POLL_TIMEOUT ))
RETRIES=0
CHECKS_JSON=""

while :; do
  # --- re-read PR state; re-assert base lock at merge time --------------------
  # gh_pr_view is gh_retry-wrapped, so a transient 5xx/rate-limit during the long
  # poll backs off instead of aborting the merge driver.
  PR_JSON="$(gh_pr_view "$PR_NUM" baseRefName,state,mergeable,headRefName,title 2>/dev/null || true)"
  PR_FIELDS="$(printf '%s' "$PR_JSON" \
    | jq -r '[.baseRefName,.state,.mergeable,.headRefName,.title] | @tsv' 2>/dev/null || true)"
  if [[ -z "$PR_FIELDS" ]]; then
    log_error "merge_view" "pr-view-fail" "could not read PR #${PR_NUM}"
    exit "$EX_ERR"
  fi
  IFS=$'\t' read -r BASE STATE MERGEABLE HEAD_REF PR_TITLE <<<"$PR_FIELDS"

  if [[ "$BASE" != "$AUTO_BASE_BRANCH" ]]; then
    log_error "merge_base_drift" "base-drift" "PR #${PR_NUM} base drifted to '${BASE}'"
    exit "$EX_PR_VERIFY"
  fi
  if [[ "$STATE" != "OPEN" ]]; then
    log_error "merge_not_open" "not-open" "PR #${PR_NUM} is not OPEN (state=${STATE})"
    exit "$EX_PR_NOT_GREEN"
  fi

  # --- required-check status. gh_pr_required_checks_json (gh.sh) normalizes the
  # `gh pr checks` exit-8 "pending" case to an array emit, so pending is detected
  # purely from the counted buckets (authoritative) rather than a raw exit code.
  CHECKS_JSON="$(gh_pr_required_checks_json "$PR_NUM" 2>/dev/null || true)"
  # Default to empty array if gh produced nothing parseable.
  [[ -n "$CHECKS_JSON" ]] || CHECKS_JSON="[]"

  FAILCOUNT="$(printf '%s' "$CHECKS_JSON" | jq '[.[] | select(.bucket=="fail" or .bucket=="cancel")] | length' 2>/dev/null || echo 0)"
  PENDING="$(printf '%s' "$CHECKS_JSON" | jq '[.[] | select(.bucket=="pending")] | length' 2>/dev/null || echo 0)"
  TOTAL="$(printf '%s' "$CHECKS_JSON" | jq 'length' 2>/dev/null || echo 0)"

  log_debug "merge_poll" "PR #${PR_NUM} checks: total=${TOTAL} fail=${FAILCOUNT} pending=${PENDING}"

  # --- failures: bounded flaky reruns of ONLY the failed required checks -------
  if [[ "${FAILCOUNT:-0}" -gt 0 ]]; then
    if [[ "$RETRIES" -lt "$FLAKY_RETRY_MAX" ]]; then
      RETRIES=$((RETRIES + 1))
      log_info "merge_flaky_rerun" "re-running ${FAILCOUNT} failed required check(s) (retry ${RETRIES}/${FLAKY_RETRY_MAX})"
      # Rerun only the workflows that own a failed required check, on this head.
      # gh_rerun_failed_workflow (gh.sh) owns the run-id lookup + `gh run rerun`,
      # both gh_retry-wrapped, and is best-effort (returns 0 even with no run id).
      while read -r wf; do
        [[ -n "$wf" ]] || continue
        gh_rerun_failed_workflow "$HEAD_REF" "$wf" || true
      done < <(printf '%s' "$CHECKS_JSON" \
                 | jq -r '.[] | select(.bucket=="fail" or .bucket=="cancel") | .workflow' \
                 | sort -u)
      sleep "$CHECK_POLL_INTERVAL"
      continue
    fi
    # Flaky budget exhausted -> escalate, never merge red.
    escalate "ci-failure"
    exit "$EX_PR_NOT_GREEN"
  fi

  # --- pending: keep polling until the hard ceiling, then escalate -------------
  # gh_pr_required_checks_json folds the exit-8 "pending" case into the array, so
  # the counted PENDING is authoritative. A zero-row result (TOTAL==0) means the
  # required checks have not reported yet — treat as pending, NEVER as all-green,
  # so we cannot fall through and merge an unverified PR (GREEN FLOOR already
  # proved the required set is non-empty).
  if [[ "${PENDING:-0}" -gt 0 || "${TOTAL:-0}" -eq 0 ]]; then
    if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
      escalate "ci-timeout"
      exit "$EX_PR_NOT_GREEN"
    fi
    sleep "$CHECK_POLL_INTERVAL"
    continue
  fi

  # --- all required checks green. handle conflict / behind-base (NO force) -----
  # git_pr_update_branch (git.sh) does the merge-from-base via the gh API and
  # classifies the outcome: 0 = updated (re-poll), EX_PR_CONFLICT = unresolvable
  # without force (escalate), EX_ERR = other transient/API error (re-poll).
  if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
    log_info "merge_update_branch" "PR #${PR_NUM} conflicting; attempting merge-from-base (no force)"
    set +e
    git_pr_update_branch "$PR_NUM"
    UB_RC=$?
    set -e
    case "$UB_RC" in
      0)
        log_info "merge_update_branch_ok" "updated PR #${PR_NUM} branch from base; re-polling CI"
        sleep "$CHECK_POLL_INTERVAL"
        continue ;;
      "$EX_PR_CONFLICT")
        # A real conflict requiring human resolution. NO force.
        escalate "conflict"
        exit "$EX_PR_CONFLICT" ;;
      *)
        # Transient/API error: give it a beat and re-poll rather than escalate.
        sleep "$CHECK_POLL_INTERVAL"
        continue ;;
    esac
  fi

  # MERGEABLE may be UNKNOWN (GitHub still computing); give it a beat then re-poll.
  if [[ "$MERGEABLE" == "UNKNOWN" ]]; then
    if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
      escalate "ci-timeout"
      exit "$EX_PR_NOT_GREEN"
    fi
    log_debug "merge_mergeable_unknown" "mergeability still computing; re-polling"
    sleep "$CHECK_POLL_INTERVAL"
    continue
  fi

  # --------------------------------------------------------------------------- #
  # MERGE — squash. Subject = PR title (a conventional commit); body SCRUBBED to
  # empty so no Co-Authored-By trailer from any underlying commit can survive (HC6).
  # --delete-branch keeps the auto/* head branches from accumulating.
  # --------------------------------------------------------------------------- #
  if gh_retry gh.merge_squash -- pr merge "$PR_NUM" --squash --delete-branch \
       --subject "$PR_TITLE" --body "" >/dev/null 2>&1; then
    log_info "merge_ok" "merged PR #${PR_NUM} into ${AUTO_BASE_BRANCH} via squash"
    exit "$EX_OK"
  fi

  # Merge call failed despite green — re-read once; if conflict appeared, resolve
  # via merge-from-base; otherwise treat as not-green/blocked and escalate (never
  # loop forever).
  RECHECK_MERGEABLE="$(gh_pr_view "$PR_NUM" mergeable 2>/dev/null | jq -r '.mergeable // empty' 2>/dev/null || true)"
  if [[ "$RECHECK_MERGEABLE" == "CONFLICTING" ]]; then
    set +e
    git_pr_update_branch "$PR_NUM"
    UB_RC=$?
    set -e
    case "$UB_RC" in
      0|"$EX_ERR")
        sleep "$CHECK_POLL_INTERVAL"
        continue ;;
      *)
        escalate "conflict"
        exit "$EX_PR_CONFLICT" ;;
    esac
  fi
  log_error "merge_call_fail" "merge-rejected" "gh pr merge failed for PR #${PR_NUM} (mergeable=${RECHECK_MERGEABLE})"
  escalate "ci-failure"
  exit "$EX_PR_NOT_GREEN"
done
