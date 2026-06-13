#!/usr/bin/env bash
# shellcheck shell=bash
#
# git.sh — git-only helpers for /auto's branch/worktree lifecycle.
#
# Scope (decisions.md D1/§2, architecture §3.7/§4):
#   - fetch develop-auto (the ONE base every PR targets; HARD LOCK).
#   - per-issue worktrees under .auto/worktrees/issue-<N> (disposable; gitignored).
#   - branch creation strictly FROM origin/develop-auto, named auto/<type>/<N>-<slug>.
#   - portable slugify.
#   - merge-base ancestry checks (branch-origin guard for auto-pr-create).
#   - conflict resolution via `gh pr update-branch` (merge-from-base) ONLY.
#
# HARD RULE (decisions.md §2 / critical-rules): force-push is FORBIDDEN, ever, on
# any branch. There is NO `git push --force` / `--force-with-lease` anywhere here.
# Conflicts are resolved by merging the base IN (no rewrite of pushed history).
#
# Sourced (never executed) by bin/*.sh. Depends on constants.sh + log.sh, and on
# gh.sh for the no-force update-branch path (which goes through the gh API).
#
set -euo pipefail

_AUTO_GIT_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -z "${AUTO_CONSTANTS_SOURCED:-}" ]]; then
  # shellcheck source=constants.sh
  source "${_AUTO_GIT_LIBDIR}/constants.sh"
fi
if [[ -z "${AUTO_LOG_SOURCED:-}" ]]; then
  # shellcheck source=log.sh
  source "${_AUTO_GIT_LIBDIR}/log.sh"
fi
# gh.sh provides gh_pr_for_head / gh_retry for the update-branch conflict path.
if [[ -z "${AUTO_GH_SOURCED:-}" ]]; then
  # shellcheck source=gh.sh
  source "${_AUTO_GIT_LIBDIR}/gh.sh"
fi

if [[ -n "${AUTO_GIT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly AUTO_GIT_SOURCED=1

# =========================================================================== #
# 1. SLUGIFY (decisions.md §5 branch naming; architecture §4).
#    lowercase -> non-alnum to '-', collapse repeats, trim, cap AUTO_SLUG_MAXLEN.
# =========================================================================== #

# git_slugify <text>
#   Print a branch-safe slug. Empty/edge input yields "x" so a branch name is
#   never malformed (auto/<type>/<N>- with an empty slug is undesirable).
git_slugify() {
  local raw="${1-}" slug
  slug="$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-"${AUTO_SLUG_MAXLEN}")"
  # Trim a trailing '-' left by the cut, and fall back if empty.
  slug="${slug%-}"
  [[ -z "$slug" ]] && slug="x"
  printf '%s\n' "$slug"
}

# git_branch_name <type> <issue#> <title>
#   Compose the canonical branch name auto/<type>/<N>-<slug>. <type> is validated
#   against AUTO_BRANCH_TYPES; an unknown type falls back to 'chore' (fail-safe)
#   with a warning so a bad caller never produces an out-of-policy branch name.
git_branch_name() {
  local type="${1:?git_branch_name: type required}"
  local n="${2:?git_branch_name: issue# required}"
  local title="${3-}"
  local ok=0 t
  for t in $AUTO_BRANCH_TYPES; do [[ "$type" == "$t" ]] && ok=1 && break; done
  if (( ! ok )); then
    log_debug "git.branch_name" "unknown-type '${type}' -> 'chore'"
    type="chore"
  fi
  printf '%s/%s/%s-%s\n' "$AUTO_BRANCH_PREFIX" "$type" "$n" "$(git_slugify "$title")"
}

# =========================================================================== #
# 2. FETCH (keep origin/develop-auto current before any branch/worktree op).
# =========================================================================== #

# git_fetch_base
#   Fetch the latest origin/develop-auto (and prune deleted remote branches).
#   Idempotent. Returns 0 on success; logs + propagates on failure.
git_fetch_base() {
  log_debug "git.fetch_base" "fetching origin/${AUTO_BASE_BRANCH}"
  if ! git fetch --prune origin "$AUTO_BASE_BRANCH" >/dev/null 2>&1; then
    log_error "git.fetch_base" "fetch-failed" "origin/${AUTO_BASE_BRANCH}"
    return "$EX_ERR"
  fi
  return 0
}

# git_base_tip
#   Print the current commit SHA of origin/develop-auto. Caller should
#   git_fetch_base first for freshness.
git_base_tip() {
  git rev-parse "origin/${AUTO_BASE_BRANCH}" 2>/dev/null || {
    log_error "git.base_tip" "no-origin-base" "origin/${AUTO_BASE_BRANCH} not found"
    return "$EX_ERR"; }
}

# =========================================================================== #
# 3. WORKTREES (architecture §3.7) — one per claimed issue, disposable cache.
#    Layout: ${AUTO_WORKTREES_DIR}/issue-<N>  (a.k.a. .auto/worktrees/issue-<N>).
#    git forbids checking out the same branch in two worktrees of one clone =>
#    a free local double-work guard within a process.
# =========================================================================== #

# git_worktree_path <issue#>
#   Print the canonical worktree path for an issue.
git_worktree_path() {
  local n="${1:?git_worktree_path: issue# required}"
  printf '%s/issue-%s\n' "$AUTO_WORKTREES_DIR" "$n"
}

# git_worktree_prune
#   GC worktree admin entries for directories that no longer exist (crashed
#   runs). Safe/idempotent; run at iteration top.
git_worktree_prune() {
  git worktree prune >/dev/null 2>&1 || true
  log_debug "git.worktree_prune" "pruned stale worktree entries"
}

# git_worktree_add <issue#> <branch>
#   Create a worktree at .auto/worktrees/issue-<N> with <branch> branched FROM
#   origin/develop-auto (decisions.md §5: always from origin/develop-auto).
#   Idempotent-ish: if the worktree dir already exists and is a valid worktree
#   on the right branch, it is reused; otherwise stale state is pruned first.
#   Prints the worktree path on success.
git_worktree_add() {
  local n="${1:?git_worktree_add: issue# required}"
  local branch="${2:?git_worktree_add: branch required}"
  local path; path="$(git_worktree_path "$n")"

  git_fetch_base || return "$?"
  git_worktree_prune

  # Reuse an existing valid worktree on the expected branch.
  if [[ -d "$path/.git" || -f "$path/.git" ]]; then
    local cur
    cur="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$cur" == "$branch" ]]; then
      log_info "git.worktree_add" "reuse path=${path} branch=${branch} issue=${n}"
      printf '%s\n' "$path"
      return 0
    fi
    log_debug "git.worktree_add" "path exists on wrong branch (${cur}); removing"
    git_worktree_remove "$n" || true
  fi

  mkdir -p "$AUTO_WORKTREES_DIR"

  # -B creates/resets the branch to origin/develop-auto. If the branch already
  # exists (e.g. a prior crashed run left it), -B repoints it to the fresh base
  # tip — acceptable because no PR exists yet for an unclaimed/reclaimed issue
  # and we never force-push; the branch is local until git_push.
  if ! git worktree add -B "$branch" "$path" "origin/${AUTO_BASE_BRANCH}" >/dev/null 2>&1; then
    log_error "git.worktree_add" "worktree-add-failed" \
      "issue=${n} branch=${branch} path=${path}"
    return "$EX_ERR"
  fi
  log_info "git.worktree_add" "created path=${path} branch=${branch} from origin/${AUTO_BASE_BRANCH} issue=${n}"
  printf '%s\n' "$path"
}

# git_worktree_remove <issue#>
#   Remove the issue's worktree (force, since the engine may leave a dirty tree
#   on crash). Idempotent: a missing worktree is not an error.
git_worktree_remove() {
  local n="${1:?git_worktree_remove: issue# required}"
  local path; path="$(git_worktree_path "$n")"
  if git worktree remove --force "$path" >/dev/null 2>&1; then
    log_info "git.worktree_remove" "removed path=${path} issue=${n}"
  else
    # Maybe the admin entry is gone but the dir lingers, or vice-versa: clean both.
    [[ -d "$path" ]] && rm -rf "$path" 2>/dev/null || true
    git worktree prune >/dev/null 2>&1 || true
    log_debug "git.worktree_remove" "remove tolerated/cleaned path=${path} issue=${n}"
  fi
  return 0
}

# git_worktree_count
#   Print the number of live /auto issue worktrees (the per-process input to the
#   concurrency ceiling, architecture §3.2). Counts only paths under
#   AUTO_WORKTREES_DIR so unrelated worktrees are ignored.
git_worktree_count() {
  git worktree list --porcelain 2>/dev/null \
    | awk -v d="$AUTO_WORKTREES_DIR/issue-" '/^worktree /{ if (index($2, d)==1) c++ } END{ print c+0 }'
}

# git_delete_local_branch <branch>
#   Delete a local branch (best-effort). Used in cleanup ONLY when no PR was
#   opened for the issue (a pushed branch backing an open PR is never deleted
#   locally here — the merge step deletes the remote head via gh).
git_delete_local_branch() {
  local branch="${1:?git_delete_local_branch: branch required}"
  git branch -D "$branch" >/dev/null 2>&1 || true
  log_debug "git.delete_local_branch" "branch=${branch}"
  return 0
}

# =========================================================================== #
# 4. MERGE-BASE ANCESTRY (auto-pr-create Guard 2, architecture §2.1).
# =========================================================================== #

# git_is_ancestor <maybe-ancestor> <descendant>
#   Predicate: true (0) iff <maybe-ancestor> is an ancestor of <descendant>.
git_is_ancestor() {
  local a="${1:?git_is_ancestor: ancestor required}"
  local b="${2:?git_is_ancestor: descendant required}"
  git merge-base --is-ancestor "$a" "$b" 2>/dev/null
}

# git_branch_derives_from_base <head-branch>
#   GUARD 2 for PR creation: the head branch must derive from origin/develop-auto
#   (decisions.md D1/§5). True iff the merge-base of the head branch and the base
#   tip is itself an ancestor of the base tip (sanity that holds after a
#   merge-from-base update too). Caller maps a false result to EX_PR_PUSH (71).
git_branch_derives_from_base() {
  local head="${1:?git_branch_derives_from_base: head-branch required}"
  git_fetch_base || return "$?"
  local base_tip mb
  base_tip="$(git_base_tip)" || return "$?"
  mb="$(git merge-base "$base_tip" "$head" 2>/dev/null || true)"
  if [[ -z "$mb" ]]; then
    log_error "git.derives_from_base" "no-merge-base" "head=${head} base=origin/${AUTO_BASE_BRANCH}"
    return 1
  fi
  git_is_ancestor "$mb" "$base_tip"
}

# =========================================================================== #
# 5. PUSH (sanctioned: push the auto/* head branch only; NEVER develop/main;
#    NEVER force). decisions.md §5.
# =========================================================================== #

# git_push_head <branch> [worktree-path]
#   Push <branch> to origin and set upstream. Refuses any branch that is not an
#   auto/* head branch (defense against pushing develop/main). NEVER uses --force.
#   If <worktree-path> is given, the push runs from inside it (so the branch is
#   resolvable in a worktree-scoped clone).
git_push_head() {
  local branch="${1:?git_push_head: branch required}"
  local wt="${2:-}"
  case "$branch" in
    "${AUTO_BRANCH_PREFIX}/"*) : ;;  # ok: an auto/* head branch.
    *)
      log_error "git.push_head" "refused-non-auto-branch" \
        "will only push ${AUTO_BRANCH_PREFIX}/* head branches, got '${branch}'"
      return "$EX_PR_PUSH" ;;
  esac
  # Hard guard against any accidental force-push wiring (decisions.md §2).
  if [[ "${AUTO_ALLOW_FORCE_PUSH:-0}" != "0" ]]; then
    log_error "git.push_head" "force-push-forbidden" "AUTO_ALLOW_FORCE_PUSH must stay 0"
    return "$EX_PR_PUSH"
  fi
  local -a g=(git)
  [[ -n "$wt" ]] && g=(git -C "$wt")
  if ! "${g[@]}" push -u origin "$branch" >/dev/null 2>&1; then
    log_error "git.push_head" "push-failed" "branch=${branch}"
    return "$EX_PR_PUSH"
  fi
  log_info "git.push_head" "pushed branch=${branch}"
  return 0
}

# =========================================================================== #
# 6. CONFLICT RESOLUTION — NO FORCE (decisions.md §2; architecture §2.3).
#    The ONLY sanctioned path is `gh pr update-branch` = merge origin/develop-auto
#    INTO the PR head branch. This never rewrites pushed history, so it cannot be
#    a force-push. If the merge itself conflicts, /auto cannot resolve it
#    autonomously and the caller escalates (EX_PR_CONFLICT, 75).
# =========================================================================== #

# git_pr_update_branch <pr#>
#   Update the PR's head branch by merging its base IN, via the gh API
#   (merge-from-base, NO force). Returns:
#     0  -> branch updated (or already up to date); re-poll CI.
#     EX_PR_CONFLICT (75) -> merge conflict that auto cannot resolve; escalate.
#     EX_ERR (1) -> other transient/API error (caller may retry or escalate).
#   gh pr update-branch exits non-zero with a "merge conflict" message when the
#   base cannot be merged cleanly; we classify that distinctly.
git_pr_update_branch() {
  local pr="${1:?git_pr_update_branch: pr# required}"
  local out rc
  set +e
  out="$(gh pr update-branch "$pr" 2>&1)"
  rc=$?
  set -e
  if (( rc == 0 )); then
    log_info "git.pr_update_branch" "updated pr=${pr} (merged ${AUTO_BASE_BRANCH} in, no force)"
    return 0
  fi
  case "$out" in
    *"already up to date"*|*"already up-to-date"*|*"not behind"*|*"no new commits"*)
      log_debug "git.pr_update_branch" "pr=${pr} already current"
      return 0 ;;
    *"conflict"*|*"cannot be cleanly merged"*|*"not mergeable"*)
      log_error "git.pr_update_branch" "merge-conflict-unresolved" \
        "pr=${pr} cannot merge ${AUTO_BASE_BRANCH} cleanly (no force-push allowed) -- ${out:0:160}"
      return "$EX_PR_CONFLICT" ;;
    *)
      log_error "git.pr_update_branch" "update-branch-failed" "pr=${pr} -- ${out:0:200}"
      return "$EX_ERR" ;;
  esac
}

# =========================================================================== #
# 7. STAGED-DIFF HELPERS (used by commit-gate / gitleaks wrappers).
# =========================================================================== #

# git_has_staged_changes [worktree-path]
#   Predicate: true iff there are staged changes (something to commit / scan).
git_has_staged_changes() {
  local wt="${1:-}"
  local -a g=(git)
  [[ -n "$wt" ]] && g=(git -C "$wt")
  ! "${g[@]}" diff --cached --quiet 2>/dev/null
}
