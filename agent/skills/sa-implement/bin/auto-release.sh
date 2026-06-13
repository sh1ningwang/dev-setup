#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-release.sh — release a per-issue claim on success / failure / crash.
#
# ALWAYS run via a shell trap around the per-issue body so even a crash releases
# the lease (decisions.md §4 / architecture §3.3). Three outcomes:
#
#   success      : the PR is open. Move issue to status:in-review, keep the
#                  assignee (the PR now owns the issue), drop auto:claimed +
#                  status:in-progress, post a kind=done-pr lease (with PR URL if
#                  given). The issue is NOT re-queued.
#
#   recoverable  : a transient/recoverable failure. Restore auto:eligible, drop
#                  auto:claimed + status:in-progress, remove the assignee, post a
#                  kind=release lease with the reason. The issue returns to the queue.
#
#   hard         : a hard failure / bounded review rounds exhausted. Move issue to
#                  status:blocked (human needed), drop auto:claimed + eligible +
#                  in-progress, post a kind=release lease, and file a HUMAN-GATED
#                  escalation issue labeled auto:hold + status:triage (NOT
#                  auto-pickable; decisions.md §2). The original issue is parked.
#
# The OUTCOME is chosen from the <reason>:
#   - reason "success" / "done-pr" / "pr-open"        -> success
#   - reason starting "hard" / "blocked" / "escalate" -> hard
#   - reason "max-rounds" / "rounds-exhausted"        -> hard
#   - everything else (incl. "trap-rc-<n>")           -> recoverable (fail-safe:
#       a crash re-queues the work rather than blocking it)
#   ...or force it explicitly with --outcome.
#
# All gh operations run as the installing user's ACTIVE local gh account
# (resolved at runtime, never via `gh auth switch`); identity drift is HARD-REFUSED.
# git+gh ONLY. Idempotent: safe to call twice (the second call is a near no-op).
#
# Trap installation (portable) in the per-issue driver:
#   RELEASED=0
#   on_exit(){ rc=$?; [ -n "$CLAIMED_ISSUE" ] && [ "$RELEASED" != 1 ] \
#                && auto-release.sh "$CLAIMED_ISSUE" "trap-rc-$rc"; }
#   trap on_exit EXIT INT TERM
#
# Usage:
#   auto-release.sh <issue#> <reason> [--outcome success|recoverable|hard]
#                                     [--pr <url-or-#>] [--runner <id>]
#
# Exit codes (decisions.md §6):
#   0   release applied (or already released).
#   69  gh account could not be resolved, or drifted from the run identity.
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

export AUTO_PHASE="${AUTO_PHASE:-release}"

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
ISSUE=""
REASON=""
OUTCOME=""        # success | recoverable | hard ; empty => infer from REASON.
PR_REF=""
RUNNER="${AUTO_RUNNER_ID:-}"

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outcome) OUTCOME="${2:?--outcome requires a value}"; shift 2 ;;
    --pr)      PR_REF="${2:?--pr requires a value}"; shift 2 ;;
    --runner)  RUNNER="${2:?--runner requires a value}"; shift 2 ;;
    -h|--help) print_help ;;
    -*) log_error "release_args" "unknown-arg" "unknown argument: $1"; exit "$EX_ERR" ;;
    *)
      if [[ -z "$ISSUE" ]]; then ISSUE="$1"; shift
      elif [[ -z "$REASON" ]]; then REASON="$1"; shift
      else log_error "release_args" "extra-arg" "unexpected argument: $1"; exit "$EX_ERR"; fi ;;
  esac
done

[[ -n "$ISSUE" ]]  || { log_error "release_args" "no-issue" "usage: auto-release.sh <issue#> <reason>"; exit "$EX_ERR"; }
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { log_error "release_args" "bad-issue" "issue must be a number: $ISSUE"; exit "$EX_ERR"; }
REASON="${REASON:-unspecified}"
[[ -n "$RUNNER" ]] || RUNNER="${AUTO_RUNNER_PREFIX}-$(hostname -s 2>/dev/null || echo host)-$$"
export AUTO_ISSUE="$ISSUE"

# --------------------------------------------------------------------------- #
# Infer outcome from the reason if not forced. Fail-safe default = recoverable
# (a crash re-queues rather than blocking).
# --------------------------------------------------------------------------- #
if [[ -z "$OUTCOME" ]]; then
  case "$REASON" in
    success|done-pr|pr-open|pr-opened) OUTCOME="success" ;;
    hard*|blocked*|escalate*|max-rounds|rounds-exhausted|rearm-exhausted) OUTCOME="hard" ;;
    *) OUTCOME="recoverable" ;;
  esac
fi
case "$OUTCOME" in
  success|recoverable|hard) : ;;
  *) log_error "release_args" "bad-outcome" "--outcome must be success|recoverable|hard"; exit "$EX_ERR" ;;
esac

# --------------------------------------------------------------------------- #
# Account resolution (the ACTIVE local gh login; no switch).
# --------------------------------------------------------------------------- #
gh_select_account >/dev/null || exit "$EX_PREFLIGHT_ACCOUNT"

log_info "release_start" "issue=${ISSUE} outcome=${OUTCOME} reason=${REASON} runner=${RUNNER}"

# --------------------------------------------------------------------------- #
# Lease-comment helpers (mirror auto-claim.sh marker spelling exactly).
# --------------------------------------------------------------------------- #
_lease_marker_kv() {
  # $1 runner  $2 kind  $3 ttl  $4 reason(optional)
  local runner="$1" kind="$2" ttl="$3" reason="${4:-}"
  if [[ -n "$reason" ]]; then
    printf '%s runner="%s" ttl_seconds="%s" kind="%s" reason="%s" -->' \
      "$AUTO_LEASE_MARKER_PREFIX" "$runner" "$ttl" "$kind" "$reason"
  else
    printf '%s runner="%s" ttl_seconds="%s" kind="%s" -->' \
      "$AUTO_LEASE_MARKER_PREFIX" "$runner" "$ttl" "$kind"
  fi
}

# --------------------------------------------------------------------------- #
# OUTCOME: success — PR is open; hand the issue to review.
# --------------------------------------------------------------------------- #
release_success() {
  local body
  body="$(printf '%s\n\n🤖 /auto — runner `%s` opened a PR for this issue.%s\n' \
            "$(_lease_marker_kv "$RUNNER" "$AUTO_LEASE_KIND_DONE" "0")" \
            "$RUNNER" \
            "${PR_REF:+ PR: ${PR_REF}}")"
  gh_issue_comment "$ISSUE" "$body" >/dev/null 2>&1 \
    || log_debug "release_done_comment" "comment-tolerated issue=${ISSUE}"

  # Lifecycle: in-progress -> in-review. Keep assignee (PR owns the issue).
  gh_issue_add_labels    "$ISSUE" "$AUTO_LABEL_STATUS_IN_REVIEW" || true
  gh_issue_remove_labels "$ISSUE" "$AUTO_LABEL_STATUS_IN_PROGRESS" "$AUTO_LABEL_CLAIMED" "$AUTO_LABEL_ELIGIBLE" || true
  log_info "release_success" "issue=${ISSUE} -> ${AUTO_LABEL_STATUS_IN_REVIEW} (PR ${PR_REF:-?})"
}

# --------------------------------------------------------------------------- #
# OUTCOME: recoverable — re-queue the issue for another attempt.
# --------------------------------------------------------------------------- #
release_recoverable() {
  local body
  body="$(printf '%s\n\n🤖 /auto — runner `%s` released this issue back to the queue (%s).\n' \
            "$(_lease_marker_kv "$RUNNER" "$AUTO_LEASE_KIND_RELEASE" "0" "$REASON")" \
            "$RUNNER" "$REASON")"
  gh_issue_comment "$ISSUE" "$body" >/dev/null 2>&1 \
    || log_debug "release_recoverable_comment" "comment-tolerated issue=${ISSUE}"

  gh_issue_add_labels    "$ISSUE" "$AUTO_LABEL_ELIGIBLE" || true
  gh_issue_remove_labels "$ISSUE" "$AUTO_LABEL_CLAIMED" "$AUTO_LABEL_STATUS_IN_PROGRESS" || true
  gh_issue_remove_assignee "$ISSUE" "$AUTO_GH_ACCOUNT" || true
  log_info "release_recoverable" "issue=${ISSUE} -> ${AUTO_LABEL_ELIGIBLE} (re-queued; reason=${REASON})"
}

# --------------------------------------------------------------------------- #
# OUTCOME: hard — block the issue + file a HUMAN-GATED escalation issue.
#   Escalation issue is auto:hold + status:triage + (best-effort) the original's
#   type:* label. NOT auto:eligible -> it never re-enters the autonomous queue
#   (decisions.md §2: bounded escalation, no auto-loop).
# --------------------------------------------------------------------------- #
release_hard() {
  local body
  body="$(printf '%s\n\n🤖 /auto — runner `%s` BLOCKED this issue (%s); escalating to a human.\n' \
            "$(_lease_marker_kv "$RUNNER" "$AUTO_LEASE_KIND_RELEASE" "0" "$REASON")" \
            "$RUNNER" "$REASON")"
  gh_issue_comment "$ISSUE" "$body" >/dev/null 2>&1 \
    || log_debug "release_hard_comment" "comment-tolerated issue=${ISSUE}"

  # Park the original issue: blocked, no longer claimed/eligible/in-progress.
  gh_issue_add_labels    "$ISSUE" "$AUTO_LABEL_STATUS_BLOCKED" || true
  gh_issue_remove_labels "$ISSUE" "$AUTO_LABEL_CLAIMED" "$AUTO_LABEL_ELIGIBLE" "$AUTO_LABEL_STATUS_IN_PROGRESS" || true
  gh_issue_remove_assignee "$ISSUE" "$AUTO_GH_ACCOUNT" || true

  # Carry the original issue's type:* label onto the escalation (best-effort).
  local type_label=""
  local issue_json labels_csv t
  issue_json="$(gh_issue_view "$ISSUE" "labels,title,url" 2>/dev/null || echo '{}')"
  labels_csv="$(printf '%s' "$issue_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || true)"
  for t in $AUTO_LABELS_TYPE; do
    case ",$labels_csv," in *,"$t",*) type_label="$t"; break ;; esac
  done
  local orig_title orig_url
  orig_title="$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null || true)"
  orig_url="$(printf '%s' "$issue_json" | jq -r '.url // ""' 2>/dev/null || true)"

  # Build the escalation issue body + labels.
  local esc_title esc_body esc_url esc_num
  esc_title="follow-up(#${ISSUE}): /auto could not converge"
  esc_body="$(cat <<EOF
${AUTO_ESCALATION_MARKER_PREFIX} issue="${ISSUE}" -->

# Escalation for #${ISSUE}

\`/auto\` blocked issue #${ISSUE}${orig_title:+ (\"${orig_title}\")} and is escalating to a human.

- **Reason:** ${REASON}
- **Original issue:** ${orig_url:-#${ISSUE}}
- **Runner:** \`${RUNNER}\`
${PR_REF:+- **PR (left for review):** ${PR_REF}}

This issue is **human-gated** (\`${AUTO_LABEL_HOLD}\` + \`${AUTO_LABEL_STATUS_TRIAGE}\`); \`/auto\`
will NOT pick it up automatically. A human should triage, then either remove
\`${AUTO_LABEL_HOLD}\` and add \`${AUTO_LABEL_ELIGIBLE}\` to re-enter the queue, or close it.
EOF
)"

  # Idempotent (header contract): never file a DUPLICATE escalation for this issue.
  # Escalations carry auto:hold; post-filter their bodies for THIS issue's marker so a
  # crash-then-rerun or a double-call cannot spam follow-ups.
  local existing
  existing="$(gh_retry gh.escalation_find -- issue list --state open --label "$AUTO_LABEL_HOLD" \
                --json number,body --limit 100 \
              | jq -r --arg m "${AUTO_ESCALATION_MARKER_PREFIX} issue=\"${ISSUE}\" -->" \
                  '[.[] | select(.body | contains($m))][0].number // empty' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    log_info "release_hard" "issue=${ISSUE} escalation #${existing} already on file; not duplicating"
    gh_issue_comment "$ISSUE" "🤖 /auto escalation already on file: #${existing} (human-gated)." >/dev/null 2>&1 || true
    return 0
  fi

  local create_args=(issue create --title "$esc_title" --body "$esc_body"
                     --label "$AUTO_LABEL_HOLD" --label "$AUTO_LABEL_STATUS_TRIAGE")
  [[ -n "$type_label" ]] && create_args+=(--label "$type_label")

  esc_url="$(gh_retry gh.escalation_create -- "${create_args[@]}" 2>/dev/null || true)"
  if [[ -n "$esc_url" ]]; then
    esc_num="$(printf '%s\n' "$esc_url" | grep -oE '[0-9]+$' | tail -1 || true)"
    log_info "release_hard" "issue=${ISSUE} -> ${AUTO_LABEL_STATUS_BLOCKED}; escalation #${esc_num:-?} filed (${AUTO_LABEL_HOLD}+${AUTO_LABEL_STATUS_TRIAGE})"
    # Link the escalation back on the original issue for the human.
    gh_issue_comment "$ISSUE" \
      "🤖 /auto escalation filed: ${esc_url} (human-gated; \`${AUTO_LABEL_HOLD}\`)." >/dev/null 2>&1 || true
  else
    log_error "release_hard" "escalation-create-failed" \
      "issue=${ISSUE} blocked but escalation issue could not be filed"
    # The original issue is still safely blocked; do not fail the release.
  fi
}

# --------------------------------------------------------------------------- #
# Dispatch.
# --------------------------------------------------------------------------- #
case "$OUTCOME" in
  success)     release_success ;;
  recoverable) release_recoverable ;;
  hard)        release_hard ;;
esac

log_info "release_ok" "issue=${ISSUE} outcome=${OUTCOME}"
exit "$EX_OK"
