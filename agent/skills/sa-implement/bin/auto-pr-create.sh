#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-pr-create.sh — the ONLY sanctioned PR-creation path for /auto.
#
# Every PR /auto opens targets ONLY develop-auto (AUTO_BASE_BRANCH); a hard lock
# refuses any other base (decisions.md D1). Three guards make the lock PROVABLE:
#
#   Guard 1 (pre-create base-lock): requested base MUST equal AUTO_BASE_BRANCH,
#            never overridable by any arg.                              -> exit 70
#   Guard 2 (branch-origin): the head branch must derive from origin/develop-auto
#            (`git merge-base --is-ancestor`), then push it.            -> exit 71
#   Guard 3 (post-create verify): re-read the created PR's baseRefName; if GitHub
#            resolved a different base (gh-merge-base config / default-branch
#            fallback), CLOSE the PR immediately.                       -> exit 72
#
# All git/gh operations run as the installing user's ACTIVE local gh account
# (resolved at runtime, never via `gh auth switch`): identity drift is HARD-REFUSED and
# a git author/committer identity is ensured for any local git this script performs.
# NO force-push, ever (decisions.md §2).
#
# Usage:
#   auto-pr-create.sh --head <branch> --issue <N> --title <title> \
#                     (--body-file <path> | --body <text>) \
#                     [--label <name>]... [--draft] [--base <branch>] [--dir <path>]
#
#   --head <branch>     head branch (auto/<type>/<issue#>-<slug>), already committed.
#   --issue <N>         issue number this PR closes (for logging/context).
#   --title <title>     PR title (a conventional-commit subject; used as squash subject).
#   --body-file <path>  PR body file. (mutually exclusive with --body)
#   --body <text>       PR body inline.
#   --label <name>      apply this label to the PR (repeatable). Namespaced names
#                       from the canonical taxonomy (decisions.md §3).
#   --draft             open the PR as a draft.
#   --base <branch>     ONLY accepted value is develop-auto; anything else -> Guard 1.
#   --dir <path>        repo/worktree dir (default: AUTO_ROOT, else cwd).
#
# On success prints the PR NUMBER on stdout (last line) and exits 0.
#
# Exit codes (decisions.md §6):
#   0   PR created against develop-auto and verified.
#   1   generic / argument error.
#   69  gh account could not be resolved, or drifted from the run identity.
#   70  base-lock violation (requested base != develop-auto).
#   71  push fail / branch-origin violation.
#   72  post-create base-verify fail (PR base drifted; PR closed).
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

export AUTO_PHASE="${AUTO_PHASE:-pr-create}"

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
HEAD_BRANCH=""
ISSUE=""
TITLE=""
BODY_FILE=""
BODY_INLINE=""
REQUESTED_BASE="$AUTO_BASE_BRANCH"
WORK_DIR="${AUTO_ROOT:-$(pwd)}"
DRAFT=0
LABELS=()
_TMP_BODY=""

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below.
cleanup() { [[ -n "$_TMP_BODY" && -f "$_TMP_BODY" ]] && rm -f "$_TMP_BODY"; return 0; }
trap cleanup EXIT

# Print the leading header comment block (top-of-file usage) and exit 0.
print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --head)      HEAD_BRANCH="${2:?--head requires a branch}"; shift 2 ;;
    --issue)     ISSUE="${2:?--issue requires a number}"; shift 2 ;;
    --title)     TITLE="${2:?--title requires text}"; shift 2 ;;
    --body-file) BODY_FILE="${2:?--body-file requires a path}"; shift 2 ;;
    --body)      BODY_INLINE="${2?--body requires text}"; shift 2 ;;
    --label)     LABELS+=("${2:?--label requires a name}"); shift 2 ;;
    --draft)     DRAFT=1; shift ;;
    --base)      REQUESTED_BASE="${2:?--base requires a branch}"; shift 2 ;;
    --dir)       WORK_DIR="${2:?--dir requires a path}"; shift 2 ;;
    -h|--help) print_help ;;
    *)
      log_error "pr_create_args" "unknown-arg" "unknown argument: $1"
      exit "$EX_ERR" ;;
  esac
done

[[ -n "$HEAD_BRANCH" ]] || { log_error "pr_create_args" "no-head" "--head is required"; exit "$EX_ERR"; }
[[ -n "$ISSUE" ]]       || { log_error "pr_create_args" "no-issue" "--issue is required"; exit "$EX_ERR"; }
[[ -n "$TITLE" ]]       || { log_error "pr_create_args" "no-title" "--title is required"; exit "$EX_ERR"; }
export AUTO_ISSUE="$ISSUE"

if [[ -n "$BODY_FILE" && -n "$BODY_INLINE" ]]; then
  log_error "pr_create_args" "ambiguous-body" "pass exactly one of --body-file / --body"
  exit "$EX_ERR"
fi
if [[ -n "$BODY_INLINE" ]]; then
  _TMP_BODY="$(mktemp -t auto-pr-body.XXXXXX)"
  printf '%s\n' "$BODY_INLINE" > "$_TMP_BODY"
  BODY_FILE="$_TMP_BODY"
fi
if [[ -z "$BODY_FILE" ]]; then
  # An empty body is acceptable; create one so --body-file always has a target.
  _TMP_BODY="$(mktemp -t auto-pr-body.XXXXXX)"
  : > "$_TMP_BODY"
  BODY_FILE="$_TMP_BODY"
fi
[[ -f "$BODY_FILE" ]] || { log_error "pr_create_args" "missing-body-file" "body file not found: $BODY_FILE"; exit "$EX_ERR"; }
[[ -d "$WORK_DIR" ]]  || { log_error "pr_create_dir" "missing-dir" "work dir does not exist: $WORK_DIR"; exit "$EX_ERR"; }

cd "$WORK_DIR"

# --------------------------------------------------------------------------- #
# Account resolution: resolve the ACTIVE local gh login and HARD-ASSERT it has not
# drifted, then ensure a git author/committer identity locally. Delegated to the
# single chokepoint gh_select_account (idempotent; gh_retry-resilient) so the
# resolution logic lives in exactly one place. Returns EX_PREFLIGHT_ACCOUNT (69) on
# any failure to resolve/assert.
# --------------------------------------------------------------------------- #
if ! gh_select_account >/dev/null; then
  log_error "pr_create_account" "wrong-account" \
    "could not resolve/assert the active gh account"
  exit "$EX_PREFLIGHT_ACCOUNT"
fi

# --------------------------------------------------------------------------- #
# GUARD 1 — base-lock pre-check. The caller may NEVER request a different base.
# --------------------------------------------------------------------------- #
if [[ "$REQUESTED_BASE" != "$AUTO_BASE_BRANCH" ]]; then
  log_error "pr_create_base_lock" "base-lock" \
    "BASE-LOCK VIOLATION: requested base '${REQUESTED_BASE}' != '${AUTO_BASE_BRANCH}'; refusing"
  exit "$EX_PR_BASE_LOCK"
fi
log_debug "pr_create_base_ok" "base locked to ${AUTO_BASE_BRANCH}"

# --------------------------------------------------------------------------- #
# GUARD 2 — branch-origin: head must derive from origin/develop-auto, then push.
# --------------------------------------------------------------------------- #
# The head branch must exist locally (the engine cut it from origin/develop-auto).
if ! git rev-parse --verify --quiet "${HEAD_BRANCH}^{commit}" >/dev/null; then
  log_error "pr_create_head" "no-head-ref" "head branch '${HEAD_BRANCH}' not found locally"
  exit "$EX_PR_PUSH"
fi

# Delegate the ancestry check (and the freshening fetch of origin/develop-auto)
# to git.sh: the head's merge-base with the base tip must itself be an ancestor of
# the base tip. Forks from other bases fail here. Maps to EX_PR_PUSH (71).
if ! git_branch_derives_from_base "$HEAD_BRANCH"; then
  log_error "pr_create_branch_origin" "branch-origin" \
    "BRANCH-ORIGIN VIOLATION: ${HEAD_BRANCH} is not derived from origin/${AUTO_BASE_BRANCH}"
  exit "$EX_PR_PUSH"
fi
log_debug "pr_create_branch_origin_ok" "head derives from ${AUTO_BASE_BRANCH}"

# Push the head branch via git.sh (NEVER force; decisions.md §2). git_push_head
# REFUSES any non-auto/* branch and re-asserts AUTO_ALLOW_FORCE_PUSH=0, so the
# force-push / branch-name safety guarantees this header advertises are enforced
# in code. Idempotent: pushing an already-up-to-date branch is a no-op success.
if ! git_push_head "$HEAD_BRANCH" "$WORK_DIR"; then
  log_error "pr_create_push" "push-fail" "failed to push head branch ${HEAD_BRANCH}"
  exit "$EX_PR_PUSH"
fi
log_info "pr_create_push_ok" "pushed ${HEAD_BRANCH} to origin"

# --------------------------------------------------------------------------- #
# Idempotency: if an OPEN PR already exists for this exact head against develop-auto,
# reuse it. Delegated to gh_pr_for_head, which queries the refs/PR API directly
# (strongly consistent, NOT the racy search index) and is gh_retry-resilient
# (architecture §3.2). Prints the PR number or empty (never "null").
# --------------------------------------------------------------------------- #
EXISTING_PR="$(gh_pr_for_head "$HEAD_BRANCH" open || true)"
if [[ -n "$EXISTING_PR" ]]; then
  log_info "pr_create_reuse" "open PR #${EXISTING_PR} already exists for ${HEAD_BRANCH}; reusing"
  PR_NUM="$EXISTING_PR"
else
  # --------------------------------------------------------------------------- #
  # Create the PR. Base is the constant (never the arg) so Guard 1 is the only knob.
  # --------------------------------------------------------------------------- #
  CREATE_ARGS=(pr create
    --base "$AUTO_BASE_BRANCH"
    --head "$HEAD_BRANCH"
    --title "$TITLE"
    --body-file "$BODY_FILE")
  [[ "$DRAFT" -eq 1 ]] && CREATE_ARGS+=(--draft)
  for lbl in "${LABELS[@]:-}"; do
    [[ -n "$lbl" ]] && CREATE_ARGS+=(--label "$lbl")
  done

  PR_URL=""
  if ! PR_URL="$(gh "${CREATE_ARGS[@]}" 2>&1)"; then
    log_error "pr_create_gh" "gh-pr-create-fail" "gh pr create failed: ${PR_URL}"
    exit "$EX_PR_PUSH"
  fi
  # The created URL's last path element is the PR number.
  PR_NUM="$(printf '%s\n' "$PR_URL" | grep -oE '[0-9]+$' | tail -1 || true)"
  if [[ -z "$PR_NUM" ]]; then
    log_error "pr_create_parse" "no-pr-number" "could not parse PR number from: ${PR_URL}"
    exit "$EX_ERR"
  fi
  log_info "pr_create_created" "opened PR #${PR_NUM} against ${AUTO_BASE_BRANCH} (issue #${ISSUE})"
fi

# --------------------------------------------------------------------------- #
# Apply labels to a reused PR too (idempotent; create already applied them above).
# --------------------------------------------------------------------------- #
if [[ -n "$EXISTING_PR" ]]; then
  for lbl in "${LABELS[@]:-}"; do
    [[ -n "$lbl" ]] || continue
    gh pr edit "$PR_NUM" --add-label "$lbl" >/dev/null 2>&1 \
      || log_info "pr_create_label_warn" "WARN: could not add label '${lbl}' to PR #${PR_NUM}"
  done
fi

# --------------------------------------------------------------------------- #
# GUARD 3 — post-create verify. Re-read the actual base; if it drifted, CLOSE.
#   Makes the lock provable rather than assumed (architecture §2.1).
# --------------------------------------------------------------------------- #
ACTUAL_BASE="$(gh pr view "$PR_NUM" --json baseRefName -q .baseRefName 2>/dev/null || true)"
if [[ "$ACTUAL_BASE" != "$AUTO_BASE_BRANCH" ]]; then
  log_error "pr_create_verify" "base-drift" \
    "POST-CREATE BASE MISMATCH: PR #${PR_NUM} base='${ACTUAL_BASE}' != '${AUTO_BASE_BRANCH}'; closing"
  gh pr close "$PR_NUM" \
    --comment "Auto-closed: base must be ${AUTO_BASE_BRANCH} (was ${ACTUAL_BASE})." \
    >/dev/null 2>&1 || log_error "pr_create_close" "close-fail" "could not close mis-targeted PR #${PR_NUM}"
  exit "$EX_PR_VERIFY"
fi

log_info "pr_create_ok" "PR #${PR_NUM} verified base=${AUTO_BASE_BRANCH} (issue #${ISSUE})"
printf '%s\n' "$PR_NUM"
exit "$EX_OK"
