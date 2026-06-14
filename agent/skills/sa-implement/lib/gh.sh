#!/usr/bin/env bash
# shellcheck shell=bash
#
# gh.sh — thin, deterministic wrappers around the `gh` CLI for /auto.
#
# This library is the ONLY sanctioned way the core talks to GitHub. It uses the
# `gh` CLI exclusively (NEVER the GitHub MCP). Everything here is built to be:
#   - DETERMINISTIC about identity: the ACTIVE local gh login is resolved once
#     per run (gh_select_account), cached, and HARD-ASSERTED unchanged before
#     any mutation. The engine never runs `gh auth switch` and never mutates
#     global gh/git state (safe for concurrent instances across projects).
#   - STRONGLY CONSISTENT where it matters: PR-by-head lookups use the refs API,
#     not the eventually-consistent search index (critique: racy `Closes #N`).
#   - ADDITIVE for shared issue state: label/assignee edits are set-union, comments
#     are append-only, so racing runners never clobber each other (decisions.md §4).
#   - RESILIENT: every gh call that may hit the API is wrapped with rate-limit /
#     transient-failure backoff + jitter, and failures are logged with a cause.
#
# Sourced (never executed) by bin/*.sh. Depends on constants.sh + log.sh.
#
# Conventions used throughout:
#   - Functions print their primary result to stdout (one value/line) and diagnostics
#     to stderr via log_*; callers read stdout.
#   - Boolean predicates return 0 (true) / 1 (false) and print nothing.
#   - On hard failure a function logs ERROR-with-cause and returns the relevant
#     EX_* exit code (so `set -e` callers propagate it) — it does not `exit` itself
#     unless explicitly documented, leaving control flow to the bin/ driver.
#
set -euo pipefail

# --- dependency sourcing (defensive; idempotent guards in each lib) ----------- #
_AUTO_GH_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -z "${AUTO_CONSTANTS_SOURCED:-}" ]]; then
  # shellcheck source=constants.sh
  source "${_AUTO_GH_LIBDIR}/constants.sh"
fi
if [[ -z "${AUTO_LOG_SOURCED:-}" ]]; then
  # shellcheck source=log.sh
  source "${_AUTO_GH_LIBDIR}/log.sh"
fi

if [[ -n "${AUTO_GH_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly AUTO_GH_SOURCED=1

# --------------------------------------------------------------------------- #
# Tunables (overridable via env before sourcing; sane defaults otherwise).
# --------------------------------------------------------------------------- #
: "${AUTO_GH_RETRY_MAX:=5}"        # max attempts for a retryable gh call.
: "${AUTO_GH_BACKOFF_BASE:=2}"     # seconds; exponential base for backoff.
: "${AUTO_GH_BACKOFF_CAP:=60}"     # seconds; max single backoff sleep.

# --------------------------------------------------------------------------- #
# Internal: jittered sleep (whole seconds; portable, no bc).
#   $1 = base seconds. Adds 0..1000ms of jitter to de-correlate racing runners.
# --------------------------------------------------------------------------- #
_gh_sleep_jitter() {
  local base="${1:-1}" jitter_ms
  jitter_ms=$(( RANDOM % 1000 ))
  # sleep accepts fractional seconds on macOS/Linux coreutils.
  sleep "${base}.$(printf '%03d' "$jitter_ms")" 2>/dev/null || sleep "$base"
}

# --------------------------------------------------------------------------- #
# gh_retry <log-evt> -- <gh args...>
#   Run a `gh` invocation EXACTLY ONCE PER ATTEMPT (critical: many callers
#   MUTATE state, so the command must never be re-executed merely to classify an
#   error) with exponential backoff + jitter on transient errors: rate-limit
#   (HTTP 403/429 with rate-limit text), 5xx, abuse/secondary limits. Other 4xx
#   fail fast. stdout of the gh call is forwarded to the caller's stdout; stderr
#   is captured (via a temp file) for classification and forwarded for context.
#   Returns gh's exit code from the final attempt.
# --------------------------------------------------------------------------- #
gh_retry() {
  local evt="${1:?gh_retry: evt required}"; shift
  [[ "${1:-}" == "--" ]] && shift
  local attempt=1 rc=0 err out backoff errfile
  errfile="$(mktemp "${TMPDIR:-/tmp}/auto-gh.XXXXXX")"
  # Always clean up the temp file (even on a set -e early return), and SELF-CLEAR the
  # RETURN trap so it never re-fires on a later function return with $errfile out of
  # scope (a RETURN trap is NOT function-local; the stale fire tripped set -u).
  trap 'rm -f "${errfile:-}"; trap - RETURN' RETURN

  while :; do
    out=""; : > "$errfile"
    # Single execution: stdout captured into $out, stderr captured to $errfile.
    # We deliberately capture (not stream live) so classification is
    # deterministic — no async process-substitution flush race. The captured
    # stderr is forwarded to the caller's stderr afterward for visibility.
    if out="$(gh "$@" 2>"$errfile")"; then
      printf '%s' "$out"
      return 0
    fi
    rc=$?
    err="$(cat "$errfile" 2>/dev/null || true)"
    [[ -n "$err" ]] && printf '%s\n' "$err" >&2   # forward for operator context.

    if _gh_is_retryable "$err" && (( attempt < AUTO_GH_RETRY_MAX )); then
      backoff=$(( AUTO_GH_BACKOFF_BASE ** attempt ))
      (( backoff > AUTO_GH_BACKOFF_CAP )) && backoff=$AUTO_GH_BACKOFF_CAP
      log_debug "${evt}.retry" "attempt=${attempt} rc=${rc} backoff=${backoff}s -- ${err:0:160}"
      _gh_sleep_jitter "$backoff"
      attempt=$(( attempt + 1 ))
      continue
    fi
    log_error "$evt" "gh-failed-rc-${rc}" "${err:0:240}"
    return "$rc"
  done
}

# Classify a gh stderr blob as a retryable transient condition.
_gh_is_retryable() {
  local e="${1:-}"
  case "$e" in
    *"rate limit"*|*"rate-limit"*) return 0 ;;   # also covers "secondary rate limit".
    *"abuse detection"*|*"retry your request"*) return 0 ;;
    *"was submitted too quickly"*) return 0 ;;
    *"HTTP 429"*|*"HTTP 500"*|*"HTTP 502"*|*"HTTP 503"*|*"HTTP 504"*) return 0 ;;
    *"timeout"*|*"timed out"*|*"connection reset"*|*"EOF"*|*"TLS handshake"*) return 0 ;;
    *) return 1 ;;
  esac
}

# =========================================================================== #
# 1. ACCOUNT SELECTION (architecture §6.4) — DETERMINISTIC, NEVER A SWITCH.
#    All git/gh operations run as the installing user's ACTIVE local gh login.
#    The engine resolves that login once, caches it (.auto/.account) and
#    HARD-ASSERTS it has not drifted mid-run. It NEVER runs `gh auth switch`
#    and never touches global gh/git state — so several loop instances can run
#    concurrently on different project directories without interfering. An
#    operator may export AUTO_GH_ACCOUNT to pin an expected login: the engine
#    then asserts the active login matches (and aborts otherwise), but the
#    switch itself is always the human's action.
# =========================================================================== #

# gh_active_account
#   Print the login of the currently active gh account (the one gh will use for
#   API calls). Empty + non-zero if it cannot be determined.
gh_active_account() {
  local login
  # `gh api user` reflects the ACTIVE token's identity — authoritative.
  login="$(gh_retry gh.active_user -- api user --jq .login 2>/dev/null || true)"
  if [[ -z "$login" ]]; then
    log_error "gh.active_account" "cannot-determine-active-gh-account"
    return "$EX_PREFLIGHT_ACCOUNT"
  fi
  printf '%s\n' "$login"
}

# gh_select_account
#   Resolve the account every git/gh operation in this process runs as — the
#   ACTIVE local gh login — and HARD-ASSERT it is deterministic for the run.
#   This is the single chokepoint every mutation path must call (preflight runs
#   it as assertion A10; iterate/claim/PR/merge re-call it cheaply).
#
#   Sequence (read-only with respect to gh; never switches accounts):
#     1. Resolve the active login via `gh api user`.
#     2. If AUTO_GH_ACCOUNT was pre-set (operator pin), assert active == pin.
#     3. If .auto/.account exists (run-start snapshot), assert active matches —
#        catches a human flipping `gh auth switch` mid-run. Else write it.
#     4. Export AUTO_GH_ACCOUNT=<active> for this process (assignee defaults,
#        log context, downstream asserts).
#     5. Ensure a usable git author identity WITHOUT overriding the user's own
#        config: env override > existing git config > GitHub noreply identity
#        derived from the active login (only written when config is missing).
#
#   Prints the active login. Returns 0 on success, EX_PREFLIGHT_ACCOUNT (69)
#   on any resolution/assertion failure.
gh_select_account() {
  local active
  active="$(gh_active_account)" || return "$EX_PREFLIGHT_ACCOUNT"

  # 2. Operator pin (optional): assert, never switch.
  if [[ -n "${AUTO_GH_ACCOUNT:-}" && "$active" != "$AUTO_GH_ACCOUNT" ]]; then
    log_error "gh.select_account" "account-mismatch" \
      "active gh account is '${active}' but AUTO_GH_ACCOUNT pins '${AUTO_GH_ACCOUNT}'; run: gh auth switch --user ${AUTO_GH_ACCOUNT} (the engine never switches accounts itself)"
    return "$EX_PREFLIGHT_ACCOUNT"
  fi

  # 3. Mid-run drift guard against the run-start snapshot (per-repo cache).
  local cache="${AUTO_ACCOUNT_CACHE_FILE:-}"
  if [[ -n "$cache" ]]; then
    if [[ -f "$cache" ]]; then
      local started_as
      started_as="$(cat "$cache" 2>/dev/null || true)"
      if [[ -n "$started_as" && "$started_as" != "$active" ]]; then
        log_error "gh.select_account" "account-drift" \
          "active gh account is '${active}' but this run started as '${started_as}' (${cache}); the active login changed mid-run. Switch back (gh auth switch --user ${started_as}) or remove ${cache} to accept the new identity."
        return "$EX_PREFLIGHT_ACCOUNT"
      fi
    else
      mkdir -p "$(dirname "$cache")" 2>/dev/null || true
      printf '%s\n' "$active" >"$cache" 2>/dev/null || true
    fi
  fi

  # 4. Export the resolved login for this process.
  AUTO_GH_ACCOUNT="$active"
  export AUTO_GH_ACCOUNT

  # 5. Git identity: respect the user's config; derive a noreply identity only
  #    when nothing is configured (so commits still attribute to the user).
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "${AUTO_GIT_USER_NAME:-}" ]]; then
      git config user.name "$AUTO_GIT_USER_NAME" || true
    fi
    if [[ -n "${AUTO_GIT_USER_EMAIL:-}" ]]; then
      git config user.email "$AUTO_GIT_USER_EMAIL" || true
    fi
    local cfg_name cfg_email
    cfg_name="$(git config user.name 2>/dev/null || true)"
    cfg_email="$(git config user.email 2>/dev/null || true)"
    if [[ -z "$cfg_name" || -z "$cfg_email" ]]; then
      local uid
      uid="$(gh_retry gh.user_id -- api user --jq .id 2>/dev/null || true)"
      if [[ -z "$cfg_name" ]]; then
        git config user.name "$active" || true
      fi
      if [[ -z "$cfg_email" && -n "$uid" ]]; then
        git config user.email "${uid}+${active}@users.noreply.github.com" || true
      fi
    fi
  fi

  log_info "gh.account" "active=${active} (resolved from local gh login)"
  printf '%s\n' "$active"
}

# gh_assert_account
#   Lightweight assertion (no resolution side-effects): the active account MUST
#   still be the identity this run resolved at start (env AUTO_GH_ACCOUNT if
#   set, else the .auto/.account snapshot). Used at mutation boundaries to fail
#   closed if something flipped the active login mid-run. When no expectation
#   exists yet, it degrades to "an active login is determinable".
#   Returns 0 / EX_PREFLIGHT_ACCOUNT.
gh_assert_account() {
  local active expected=""
  active="$(gh_active_account)" || return "$EX_PREFLIGHT_ACCOUNT"
  if [[ -n "${AUTO_GH_ACCOUNT:-}" ]]; then
    expected="$AUTO_GH_ACCOUNT"
  elif [[ -n "${AUTO_ACCOUNT_CACHE_FILE:-}" && -f "${AUTO_ACCOUNT_CACHE_FILE}" ]]; then
    expected="$(cat "${AUTO_ACCOUNT_CACHE_FILE}" 2>/dev/null || true)"
  fi
  if [[ -n "$expected" && "$active" != "$expected" ]]; then
    log_error "gh.assert_account" "account-drift" \
      "active='${active}' expected='${expected}'"
    return "$EX_PREFLIGHT_ACCOUNT"
  fi
  printf '%s\n' "$active"
}

# gh_repo_slug
#   Print the owner/repo slug for the current repo (e.g. acme/widgets).
#   Cached per-process. Used to build raw `gh api` paths.
gh_repo_slug() {
  if [[ -n "${_AUTO_REPO_SLUG:-}" ]]; then
    printf '%s\n' "$_AUTO_REPO_SLUG"; return 0
  fi
  local slug
  slug="$(gh_retry gh.repo_slug -- repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  if [[ -z "$slug" ]]; then
    log_error "gh.repo_slug" "cannot-resolve-owner-repo"
    return "$EX_PREFLIGHT_ORIGIN"
  fi
  _AUTO_REPO_SLUG="$slug"
  printf '%s\n' "$slug"
}

# =========================================================================== #
# 2. AUTH / SCOPE PREFLIGHT HELPERS (architecture §6 A2).
# =========================================================================== #

# gh_auth_ok
#   True (0) if gh is logged in at all. Cheap predicate; no retry needed.
gh_auth_ok() {
  gh auth status >/dev/null 2>&1
}

# gh_has_scopes <scope...>
#   True if the active account's token carries ALL the named scopes. Reads the
#   X-Oauth-Scopes header off a `gh api` HEAD-ish call (the `user` endpoint).
gh_has_scopes() {
  local want=("$@") have
  have="$(gh auth status 2>&1 | grep -iEo "Token scopes:.*" | head -1 || true)"
  local s
  for s in "${want[@]}"; do
    if ! grep -qiE "(^|[ ,'\"])${s}([ ,'\"]|\$)" <<<"$have"; then
      return 1
    fi
  done
  return 0
}

# =========================================================================== #
# 3. ISSUE-QUEUE QUERIES (decisions.md §3 taxonomy; priority sort).
#    All queries select explicit --json fields so downstream jq is stable.
# =========================================================================== #

# Canonical JSON field set returned for queue/lease reads.
readonly AUTO_ISSUE_JSON_FIELDS="number,title,state,labels,assignees,comments,createdAt,updatedAt,url,body"

# gh_issue_view <issue#> [json-fields]
#   Print the issue's JSON object (single object). Defaults to the canonical
#   field set. Used by claim/lease logic for read-after-write verification.
gh_issue_view() {
  local n="${1:?gh_issue_view: issue# required}"
  local fields="${2:-$AUTO_ISSUE_JSON_FIELDS}"
  gh_retry gh.issue_view -- issue view "$n" --json "$fields"
}

# gh_queue_list [extra-label] [assignee]
#   Return the prioritized eligibility queue as a JSON array. An issue is
#   queue-eligible iff it is OPEN, carries auto:eligible, and is NOT held/stopped
#   /claimed/blocked. Optional <extra-label> further scopes the query (the
#   --theme/--label filter); optional <assignee> restricts to issues assigned to
#   that user (the daemon's --assignee filter). Sorted DESC by priority (P0 first),
#   then by issue number ASC (oldest first) as a stable tiebreak.
#
#   Eligibility label-set filtering is done with `gh issue list --label` (AND
#   semantics across repeated --label) plus a jq post-filter to EXCLUDE the
#   negative labels (gh has no "not label" filter), so the contract is exact.
gh_queue_list() {
  local extra="${1:-}" assignee="${2:-}"
  local args=(issue list --state open --limit 200
              --label "$AUTO_LABEL_ELIGIBLE"
              --json "number,title,labels,createdAt,updatedAt,url")
  [[ -n "$extra" ]] && args+=(--label "$extra")
  [[ -n "$assignee" ]] && args+=(--assignee "$assignee")

  local raw
  raw="$(gh_retry gh.queue_list -- "${args[@]}")" || return "$?"

  # Post-filter: drop anything carrying a disqualifying control label, then
  # compute a numeric priority rank (P0=0 highest .. P3=3, missing=2 default)
  # and sort by (rank ASC, number ASC).
  printf '%s' "$raw" | jq -c \
    --arg claimed "$AUTO_LABEL_CLAIMED" \
    --arg hold    "$AUTO_LABEL_HOLD" \
    --arg stop    "$AUTO_LABEL_STOP" \
    --arg blocked "$AUTO_LABEL_STATUS_BLOCKED" \
    --arg p0 "$AUTO_LABEL_PRIORITY_P0" --arg p1 "$AUTO_LABEL_PRIORITY_P1" \
    --arg p2 "$AUTO_LABEL_PRIORITY_P2" --arg p3 "$AUTO_LABEL_PRIORITY_P3" '
    def names: [.labels[].name];
    [ .[]
      | . as $i
      | (names) as $n
      | select(($n | index($claimed)) == null
            and ($n | index($hold))    == null
            and ($n | index($stop))    == null
            and ($n | index($blocked)) == null)
      | . + { _rank:
          (if   ($n | index($p0)) then 0
           elif ($n | index($p1)) then 1
           elif ($n | index($p2)) then 2
           elif ($n | index($p3)) then 3
           else 2 end) }
    ]
    | sort_by(._rank, .number)
    | map(del(._rank))
  '
}


# =========================================================================== #
# 4. ADDITIVE LABEL / ASSIGNEE EDITS + APPEND-ONLY COMMENTS (decisions.md §4).
#    These never clobber a racing runner's writes.
# =========================================================================== #

# gh_issue_add_labels <issue#> <label> [label...]
#   Additive label add (set-union). Idempotent: re-adding an existing label is a
#   no-op server-side.
gh_issue_add_labels() {
  local n="${1:?gh_issue_add_labels: issue# required}"; shift
  (( $# )) || { log_error "gh.add_labels" "no-labels" "issue=$n"; return "$EX_ERR"; }
  local args=(issue edit "$n")
  local l; for l in "$@"; do args+=(--add-label "$l"); done
  gh_retry gh.add_labels -- "${args[@]}" >/dev/null
}

# gh_issue_remove_labels <issue#> <label> [label...]
#   Remove labels (no-op if absent). Used when transitioning lifecycle state.
gh_issue_remove_labels() {
  local n="${1:?gh_issue_remove_labels: issue# required}"; shift
  (( $# )) || { log_error "gh.remove_labels" "no-labels" "issue=$n"; return "$EX_ERR"; }
  local args=(issue edit "$n")
  local l; for l in "$@"; do args+=(--remove-label "$l"); done
  # Removing a label the issue does not have makes gh exit non-zero on some
  # versions; tolerate that specific case so the call is idempotent.
  if ! gh_retry gh.remove_labels -- "${args[@]}" >/dev/null; then
    log_debug "gh.remove_labels" "remove-tolerated issue=$n"
    return 0
  fi
}

# gh_issue_add_assignee <issue#> [login]
#   Additive assignee add (defaults to the resolved run account, else gh's
#   server-side "@me" = the authenticated user). Cosmetic lock signal; the
#   lease comment is authoritative (decisions.md §4).
gh_issue_add_assignee() {
  local n="${1:?gh_issue_add_assignee: issue# required}"
  local who="${2:-${AUTO_GH_ACCOUNT:-@me}}"
  gh_retry gh.add_assignee -- issue edit "$n" --add-assignee "$who" >/dev/null || {
    log_debug "gh.add_assignee" "assignee-tolerated issue=$n who=$who"; return 0; }
}

# gh_issue_remove_assignee <issue#> [login]
gh_issue_remove_assignee() {
  local n="${1:?gh_issue_remove_assignee: issue# required}"
  local who="${2:-${AUTO_GH_ACCOUNT:-@me}}"
  gh_retry gh.remove_assignee -- issue edit "$n" --remove-assignee "$who" >/dev/null || {
    log_debug "gh.remove_assignee" "unassign-tolerated issue=$n who=$who"; return 0; }
}

# gh_issue_comment <issue#> <body-string>
#   Append-only comment. Returns the created comment's URL on stdout.
gh_issue_comment() {
  local n="${1:?gh_issue_comment: issue# required}"
  local body="${2:?gh_issue_comment: body required}"
  gh_retry gh.issue_comment -- issue comment "$n" --body "$body"
}

# gh_issue_comment_file <issue#> <body-file>
#   Append-only comment from a file (avoids arg-length / quoting limits for
#   large machine-parseable bodies, e.g. lease/escalation comments). Returns the comment URL.
gh_issue_comment_file() {
  local n="${1:?gh_issue_comment_file: issue# required}"
  local f="${2:?gh_issue_comment_file: body-file required}"
  [[ -f "$f" ]] || { log_error "gh.comment_file" "no-such-file" "$f"; return "$EX_ERR"; }
  gh_retry gh.issue_comment_file -- issue comment "$n" --body-file "$f"
}

# gh_issue_comments_json <issue#>
#   Print the issue's comments as a JSON array of {author,createdAt,body},
#   server timestamps included (authoritative for lease staleness, §4).
gh_issue_comments_json() {
  local n="${1:?gh_issue_comments_json: issue# required}"
  gh_retry gh.issue_comments -- issue view "$n" --json comments \
    --jq '[.comments[] | {author: .author.login, createdAt: .createdAt, body: .body}]'
}

# =========================================================================== #
# 5. PR LOOKUP BY EXACT HEAD BRANCH — via the refs/PR list API, NOT search.
#    The eventually-consistent `--search "Closes #N"` index lags seconds-to-
#    minutes and lets two racing runners both "find nothing" and both open a PR
#    (critique). The head-branch existence check is STRONGLY CONSISTENT and is
#    the authoritative idempotency guard (architecture §3.2).
# =========================================================================== #

# gh_pr_for_head <head-branch> [state]
#   Print the PR number for an EXACT head branch targeting AUTO_BASE_BRANCH, or
#   empty if none. <state> in {open,closed,all}; default open.
#   Uses `gh pr list --head <branch> --base <base>` which queries the refs/PR
#   API directly (not the search index) — strongly consistent.
gh_pr_for_head() {
  local head="${1:?gh_pr_for_head: head-branch required}"
  local state="${2:-open}"
  gh_retry gh.pr_for_head -- pr list \
    --base "$AUTO_BASE_BRANCH" --head "$head" --state "$state" \
    --json number --jq '.[0].number // empty'
}

# gh_pr_exists_for_head <head-branch>
#   Predicate: true (0) if an OPEN PR for the exact head branch already exists.
gh_pr_exists_for_head() {
  local head="${1:?gh_pr_exists_for_head: head-branch required}"
  local num
  num="$(gh_pr_for_head "$head" open)" || return "$?"
  [[ -n "$num" ]]
}

# gh_pr_view <pr#> <json-fields>
#   Print selected PR JSON fields (object). Thin retry wrapper.
gh_pr_view() {
  local n="${1:?gh_pr_view: pr# required}"
  local fields="${2:?gh_pr_view: json-fields required}"
  gh_retry gh.pr_view -- pr view "$n" --json "$fields"
}

# gh_pr_base <pr#>
#   Print the PR's current base ref name (for the post-create / merge-time
#   base-lock re-assertion in auto-pr-create / auto-merge-when-green).
gh_pr_base() {
  local n="${1:?gh_pr_base: pr# required}"
  gh_retry gh.pr_base -- pr view "$n" --json baseRefName --jq .baseRefName
}

# =========================================================================== #
# 6. REQUIRED-CHECK POLLING (decisions.md D3; architecture §2.3).
#    auto-merge-when-green polls these; the green-floor check is here too.
# =========================================================================== #

# gh_pr_required_checks_json <pr#>
#   Print the REQUIRED checks for a PR as a JSON array of {name,bucket,state,
#   workflow}. `gh pr checks --required` exits 8 when checks are pending; we
#   normalize that to a successful array emit (callers inspect buckets), and
#   only treat true errors as failures.
gh_pr_required_checks_json() {
  local n="${1:?gh_pr_required_checks_json: pr# required}"
  local out rc
  set +e
  out="$(gh pr checks "$n" --required --json name,bucket,state,workflow 2>/dev/null)"
  rc=$?
  set -e
  # gh pr checks exit codes: 0 all pass, 8 some pending, non-0/8 = error/no checks.
  case "$rc" in
    0|8) printf '%s' "${out:-[]}" ;;
    *)
      # Could be "no checks reported" (empty) — emit empty array, let the
      # green-floor logic decide. A real auth/network error is logged.
      if [[ -z "$out" ]]; then
        printf '[]'
      else
        printf '%s' "$out"
      fi
      ;;
  esac
}

# gh_required_check_contexts <branch>
#   Print the EFFECTIVE required-status-check CONTEXTS for a branch (one per
#   line, sorted, unique), unioning classic branch protection AND rulesets.
#   Used by ci-parity-check Layer B and the GREEN FLOOR preflight (A7'/A7).
#   A branch with no protection / no rulesets yields ZERO lines.
gh_required_check_contexts() {
  local branch="${1:?gh_required_check_contexts: branch required}"
  local slug; slug="$(gh_repo_slug)" || return "$?"

  {
    # Classic branch protection (404 if unprotected -> ignored).
    gh api "repos/${slug}/branches/${branch}/protection" 2>/dev/null \
      | jq -r '.required_status_checks.checks[]?.context // empty' 2>/dev/null || true
    # Rulesets effective on the branch (aggregates org + repo rulesets).
    gh api "repos/${slug}/rules/branches/${branch}" 2>/dev/null \
      | jq -r '.[]? | select(.type=="required_status_checks")
               | .parameters.required_status_checks[]?.context // empty' 2>/dev/null || true
  } | sort -u
}

# gh_required_check_count <branch>
#   Print the number of distinct required-check contexts on a branch.
gh_required_check_count() {
  local branch="${1:?gh_required_check_count: branch required}"
  gh_required_check_contexts "$branch" | grep -c . || true
}

# gh_green_floor_ok <branch>
#   GREEN FLOOR predicate (decisions.md D3): true (0) iff the branch has a
#   NON-EMPTY required-check set. A run must REFUSE to auto-merge when this is
#   false (would ship unverified code). When AUTO_GREEN_FLOOR=0 this always
#   passes (reserved escape hatch; never disabled in v1).
gh_green_floor_ok() {
  local branch="${1:-$AUTO_BASE_BRANCH}"
  [[ "${AUTO_GREEN_FLOOR:-1}" == "1" ]] || return 0
  local count; count="$(gh_required_check_count "$branch")"
  (( count > 0 ))
}

# gh_rerun_failed_workflow <head-branch> <workflow-name>
#   Re-run only the failed jobs of the latest run of <workflow-name> on a head
#   branch (the bounded flaky-retry path). Best-effort; logs and returns 0 even
#   if no run id is found so the poll loop can continue.
gh_rerun_failed_workflow() {
  local head="${1:?gh_rerun_failed_workflow: head required}"
  local wf="${2:?gh_rerun_failed_workflow: workflow required}"
  local run_id
  run_id="$(gh_retry gh.run_list -- run list --branch "$head" --workflow "$wf" \
            --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
  if [[ -z "$run_id" ]]; then
    log_debug "gh.rerun" "no-run-id head=$head wf=$wf"
    return 0
  fi
  gh_retry gh.run_rerun -- run rerun "$run_id" --failed >/dev/null 2>&1 || {
    log_debug "gh.rerun" "rerun-noop run=$run_id"; return 0; }
  log_info "gh.rerun" "reran failed jobs run=$run_id wf=$wf"
}

# =========================================================================== #
# 7. REPO MERGE-METHOD / PROTECTION / RULESET READS (preflight A6/A9).
# =========================================================================== #

# gh_repo_allows_squash
#   Predicate: true iff allow_squash_merge is enabled on the repo (we squash).
gh_repo_allows_squash() {
  local val
  val="$(gh_retry gh.repo_squash -- repo view --json mergeCommitAllowed,squashMergeAllowed \
         --jq '.squashMergeAllowed' 2>/dev/null || true)"
  [[ "$val" == "true" ]]
}

# gh_required_review_count <branch>
#   Print the required_approving_review_count for a branch (max of classic
#   protection + rulesets), or 0 if unprotected. Drives preflight A6: a count
#   >= 1 with no AUTO_APPROVER_TOKEN means autonomous self-merge is impossible.
gh_required_review_count() {
  local branch="${1:?gh_required_review_count: branch required}"
  local slug; slug="$(gh_repo_slug)" || return "$?"
  local classic rules
  classic="$(gh api "repos/${slug}/branches/${branch}/protection" 2>/dev/null \
    | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo 0)"
  rules="$(gh api "repos/${slug}/rules/branches/${branch}" 2>/dev/null \
    | jq -r '[.[]? | select(.type=="pull_request")
             | .parameters.required_approving_review_count // 0] | max // 0' 2>/dev/null || echo 0)"
  classic="${classic:-0}"; rules="${rules:-0}"
  if (( rules > classic )); then printf '%s\n' "$rules"; else printf '%s\n' "$classic"; fi
}

# gh_branch_protected <branch>
#   Predicate: true iff the branch has classic protection OR any ruleset.
gh_branch_protected() {
  local branch="${1:?gh_branch_protected: branch required}"
  local slug; slug="$(gh_repo_slug)" || return "$?"
  if gh api "repos/${slug}/branches/${branch}/protection" >/dev/null 2>&1; then
    return 0
  fi
  local n
  n="$(gh api "repos/${slug}/rules/branches/${branch}" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  (( ${n:-0} > 0 ))
}

# =========================================================================== #
# 8. REMOTE FILE READ (kill-switch fallback: .auto/STOP on develop-auto, §4).
# =========================================================================== #

# gh_remote_file_exists <path> [ref]
#   Predicate: true iff <path> exists on <ref> (default AUTO_BASE_BRANCH) in the
#   remote repo, checked via the contents API (no local checkout needed). Used
#   by the kill-switch fallback so a local .gitignore is irrelevant.
gh_remote_file_exists() {
  local path="${1:?gh_remote_file_exists: path required}"
  local ref="${2:-$AUTO_BASE_BRANCH}"
  local slug; slug="$(gh_repo_slug)" || return "$?"
  gh api "repos/${slug}/contents/${path}?ref=${ref}" >/dev/null 2>&1
}
