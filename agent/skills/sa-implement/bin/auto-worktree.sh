#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-worktree.sh — per-issue git worktree lifecycle + concurrency ceiling
# (decisions.md D8/§4; spec-concurrency §7; architecture §3.1/§3.7).
#
# `--concurrency N` parallelizes ISSUES (each its own lease + worktree + branch +
# PR). This script is the gate that creates a worktree for a freshly-claimed issue
# and is the cleanup that removes it on release. It also ENFORCES the concurrency
# ceiling before creating a new worktree.
#
# Subcommands:
#   add    --issue <N> --type <t> --title <title> [--branch <b>] [--concurrency <K>]
#          [--repo <owner/repo>] [--no-ceiling]
#       Create (or reuse) the worktree at .auto/worktrees/issue-<N> with branch
#       auto/<type>/<N>-<slug> cut FROM origin/develop-auto. Prunes stale worktrees
#       first. Enforces the ceiling unless --no-ceiling. Prints the worktree path on
#       success.
#
#   remove --issue <N> [--keep-branch] [--no-pr-check] [--repo <owner/repo>]
#       Remove the issue's worktree (force; tolerates a dirty/crashed tree). By
#       default the local branch is deleted ONLY if no open PR exists for its head
#       (a pushed branch backing an open PR is left intact). --keep-branch never
#       deletes; --no-pr-check skips the PR lookup and deletes the local branch.
#
#   count
#       Print the number of live /auto issue worktrees in THIS clone (one per line
#       of output: a single integer). The per-process input to the ceiling.
#
#   prune
#       GC worktree admin entries whose directories vanished (crashed runs).
#
# CONCURRENCY CEILING (decisions.md §4 — honestly PROBABILISTIC):
#   A new worktree is refused (exit 13, EX_CONCURRENCY) when EITHER:
#     - local live worktree count >= K, OR
#     - global open `status:in-progress` issue count >= K.
#   The global count is a read-then-act check with an inherent TOCTOU window (no
#   GitHub CAS exists); it can occasionally allow 1-over-cap across processes. The
#   per-issue claim (auto-claim.sh) is what actually prevents two runners from
#   working the SAME issue. This is documented, not papered over.
#
# Exit codes (decisions.md §6):
#   0   success.
#   1   generic / argument error.
#   13  concurrency ceiling reached (EX_CONCURRENCY) — caller skips claiming.
#
# Depends ONLY on: git, gh, jq. Sources constants/log/gh/git.
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_SELF_DIR}/../lib/constants.sh"
# shellcheck source=../lib/log.sh
source "${_SELF_DIR}/../lib/log.sh"
# shellcheck source=../lib/gh.sh
source "${_SELF_DIR}/../lib/gh.sh"
# git.sh provides the worktree/branch primitives + slugify/branch-name.
# shellcheck source=../lib/git.sh
source "${_SELF_DIR}/../lib/git.sh"

export AUTO_PHASE="${AUTO_PHASE:-worktree}"

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

[[ $# -ge 1 ]] || { log_error "wt_args" "no-subcommand" "expected: add|remove|count|prune"; exit "$EX_ERR"; }
case "${1:-}" in -h|--help) print_help ;; esac
SUBCMD="$1"; shift

# --------------------------------------------------------------------------- #
# Shared args.
# --------------------------------------------------------------------------- #
ISSUE=""
TYPE=""
TITLE=""
BRANCH=""
CONCURRENCY="${AUTO_CONCURRENCY_DEFAULT}"
REPO=""
NO_CEILING=0
KEEP_BRANCH=0
NO_PR_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)       ISSUE="${2:?--issue requires a number}"; shift 2 ;;
    --type)        TYPE="${2:?--type requires a token}"; shift 2 ;;
    --title)       TITLE="${2?--title requires text}"; shift 2 ;;
    --branch)      BRANCH="${2:?--branch requires a name}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:?--concurrency requires a number}"; shift 2 ;;
    --repo)        REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --no-ceiling)  NO_CEILING=1; shift ;;
    --keep-branch) KEEP_BRANCH=1; shift ;;
    --no-pr-check) NO_PR_CHECK=1; shift ;;
    -h|--help)     print_help ;;
    *)
      log_error "wt_args" "unknown-arg" "unknown argument: $1"
      exit "$EX_ERR" ;;
  esac
done

[[ -n "$REPO" ]] && export GH_REPO="$REPO"   # thread the repo to all gh.sh wrappers.

# =========================================================================== #
# count — live /auto issue worktrees in this clone.
# =========================================================================== #
cmd_count() {
  git_worktree_count
}

# =========================================================================== #
# prune — GC crashed worktree admin entries.
# =========================================================================== #
cmd_prune() {
  git_worktree_prune
  log_info "wt_prune" "pruned stale worktree entries"
}

# =========================================================================== #
# add — create/reuse the per-issue worktree, enforcing the concurrency ceiling.
# =========================================================================== #
cmd_add() {
  [[ -n "$ISSUE" ]] || { log_error "wt_add" "no-issue" "--issue is required"; return "$EX_ERR"; }
  export AUTO_ISSUE="$ISSUE"

  if [[ ! "$CONCURRENCY" =~ ^[0-9]+$ ]] || (( CONCURRENCY < 1 )); then
    log_error "wt_add" "bad-concurrency" "--concurrency must be a positive integer, got '${CONCURRENCY}'"
    return "$EX_ERR"
  fi

  # Always prune first so a crashed run's stale worktree does not inflate the
  # local count and falsely trip the ceiling (spec-concurrency §7).
  git_worktree_prune

  # If a worktree for THIS issue already exists, reuse it WITHOUT a ceiling check
  # (resuming an in-flight issue must not be blocked by the very count it is part
  # of). git_worktree_add is idempotent on the matching branch.
  local existing_path
  existing_path="$(git_worktree_path "$ISSUE")"
  local reusing=0
  if [[ -d "${existing_path}/.git" || -f "${existing_path}/.git" ]]; then
    reusing=1
    log_debug "wt_add" "reusing existing worktree for issue=${ISSUE} at ${existing_path}"
  fi

  # CEILING — only when creating a NEW worktree (not reuse) and not bypassed.
  if [[ "$reusing" -eq 0 && "$NO_CEILING" -eq 0 ]]; then
    local local_count global_count
    local_count="$(git_worktree_count)"
    if (( local_count >= CONCURRENCY )); then
      log_info "wt_ceiling" "local worktree count ${local_count} >= concurrency ${CONCURRENCY}; refusing issue=${ISSUE}"
      return "$EX_CONCURRENCY"
    fi
    # Global, probabilistic ceiling: open status:in-progress issues across all
    # processes/hosts (TOCTOU acknowledged; decisions.md §4). gh_count_in_progress
    # returns the count; a query failure degrades to "0" so a transient API blip
    # does not deadlock the queue (the per-issue claim still prevents double-work).
    global_count="$(gh_count_in_progress "$ISSUE" 2>/dev/null || echo 0)"   # exclude THIS issue
    [[ "$global_count" =~ ^[0-9]+$ ]] || global_count=0
    if (( global_count >= CONCURRENCY )); then
      log_info "wt_ceiling" "global OTHER status:in-progress count ${global_count} >= concurrency ${CONCURRENCY} (probabilistic); refusing issue=${ISSUE}"
      return "$EX_CONCURRENCY"
    fi
    log_debug "wt_add" "ceiling ok local=${local_count} global=${global_count} concurrency=${CONCURRENCY}"
  fi

  # Resolve the branch name. Prefer an explicit --branch; otherwise compose the
  # canonical auto/<type>/<N>-<slug> from --type + --title (git.sh validates type).
  local branch="$BRANCH"
  if [[ -z "$branch" ]]; then
    [[ -n "$TYPE" ]] || { log_error "wt_add" "no-branch-or-type" "pass --branch, or --type (+--title) to compose one"; return "$EX_ERR"; }
    branch="$(git_branch_name "$TYPE" "$ISSUE" "$TITLE")"
  fi

  # Create/reuse the worktree (git.sh handles fetch-base, prune, reuse, -B from
  # origin/develop-auto, and prints the path).
  local path
  if ! path="$(git_worktree_add "$ISSUE" "$branch")"; then
    log_error "wt_add" "worktree-add-failed" "issue=${ISSUE} branch=${branch}"
    return "$EX_ERR"
  fi
  log_info "wt_add" "ready issue=${ISSUE} branch=${branch} path=${path}"
  printf '%s\n' "$path"
}

# =========================================================================== #
# remove — cleanup on release (always safe to call; idempotent).
# =========================================================================== #
cmd_remove() {
  [[ -n "$ISSUE" ]] || { log_error "wt_remove" "no-issue" "--issue is required"; return "$EX_ERR"; }
  export AUTO_ISSUE="$ISSUE"

  # Resolve the branch this worktree is on BEFORE removing it (for the later local
  # branch-delete decision). Tolerate a missing/dead worktree.
  local path branch=""
  path="$(git_worktree_path "$ISSUE")"
  if [[ -d "${path}/.git" || -f "${path}/.git" ]]; then
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi

  # Remove the worktree (force; tolerant of a dirty tree from a crash).
  git_worktree_remove "$ISSUE"

  # Local branch cleanup. NEVER delete a branch that backs an open PR (its history
  # is the PR head); the merge step removes the remote head via gh later.
  if [[ "$KEEP_BRANCH" -eq 1 ]]; then
    log_debug "wt_remove" "keep-branch set; leaving local branch ${branch:-?} issue=${ISSUE}"
  elif [[ -z "$branch" ]]; then
    log_debug "wt_remove" "no branch resolved for issue=${ISSUE}; nothing to delete"
  else
    local has_pr=""
    if [[ "$NO_PR_CHECK" -eq 0 ]]; then
      # Strongly-consistent head-branch PR lookup (gh.sh §5), not the search index.
      has_pr="$(gh_pr_for_head "$branch" open 2>/dev/null || true)"
    fi
    if [[ -n "$has_pr" ]]; then
      log_info "wt_remove" "open PR #${has_pr} backs ${branch}; leaving local branch issue=${ISSUE}"
    else
      git_delete_local_branch "$branch"
      log_info "wt_remove" "deleted local branch ${branch} (no open PR) issue=${ISSUE}"
    fi
  fi

  log_info "wt_remove" "released worktree issue=${ISSUE} path=${path}"
  return 0
}

# --------------------------------------------------------------------------- #
# Dispatch.
# --------------------------------------------------------------------------- #
case "$SUBCMD" in
  add)    cmd_add ;;
  remove) cmd_remove ;;
  count)  cmd_count ;;
  prune)  cmd_prune ;;
  *)
    log_error "wt_args" "unknown-subcommand" "expected add|remove|count|prune, got '${SUBCMD}'"
    exit "$EX_ERR" ;;
esac
