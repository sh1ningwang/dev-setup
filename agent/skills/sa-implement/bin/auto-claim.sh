#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-claim.sh — CAS-free, race-safe per-issue claim (decisions.md §4 / D8).
#
# GitHub has NO compare-and-swap on issue mutations, so a claim is emulated with
# ADDITIVE writes + a re-read + a deterministic tie-break:
#
#   Phase A (gate)    : read the issue ONCE; refuse if not OPEN / held / blocked /
#                       not eligible (and not stale-reclaimable).        -> exit 12
#   Phase B (precheck): if a LIVE lease is held by a DIFFERENT runner, lose early.  -> exit 11
#   Phase C (write)   : add auto:claimed, drop auto:eligible, post a lease comment
#                       {runner,kind,ttl,createdAt}, assign the active gh account.
#                       All writes are additive -> a loser never clobbers a winner.
#   Phase D (confirm) : jittered re-read; among LIVE leases compute the winner
#                       (kind=reclaim newest supersedes; else OLDEST createdAt,
#                       ties by lexicographic runner). If WE won, move the issue to
#                       status:in-progress and exit 0. Else retract our lease,
#                       leave the winner's intact, and exit 11.
#
# Why this is safe without CAS: additive writes guarantee both racers observe the
# SAME comment set, apply the SAME deterministic rule, and converge on ONE winner;
# the loser voluntarily retracts. A crashed loser's lease is just a duplicate the
# winner ignores and that expires by TTL (decisions.md §4 / architecture §3.2).
#
# Stale reclaim (decisions.md §4): a lease past TTL with NO open PR for the issue
# may be reclaimed. A kind=reclaim lease supersedes any expired lease, so a revived
# dead runner (whose original lease is no longer in the live set) cannot win and
# must re-claim from scratch.
#
# All gh operations run as the installing user's ACTIVE local gh account
# (resolved at runtime, never via `gh auth switch`); identity drift from the run
# start is HARD-REFUSED before any write. git+gh ONLY (never the GitHub MCP).
#
# Usage:
#   auto-claim.sh <issue#> [--kind claim|reclaim]
#
#   <issue#>          the issue to claim.
#   --kind <kind>     claim (default) or reclaim. reclaim is used by auto-stale.sh
#                     to take over a dead runner's expired lease; it is also chosen
#                     automatically when Phase A finds the issue claimable ONLY via
#                     stale-reclaim (expired lease, no open PR).
#
# On success (exit 0) prints the winning RUNNER_ID on stdout (last line).
#
# Exit codes (decisions.md §6):
#   0   claim WON.
#   11  claim LOST (a different runner holds a live lease, or won the tie-break).
#   12  issue NOT claimable (closed / held / stopped / blocked / not eligible).
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

export AUTO_PHASE="${AUTO_PHASE:-claim}"

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
ISSUE=""
WANT_KIND="$AUTO_LEASE_KIND_CLAIM"

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind) WANT_KIND="${2:?--kind requires a value}"; shift 2 ;;
    -h|--help) print_help ;;
    -*) log_error "claim_args" "unknown-arg" "unknown argument: $1"; exit "$EX_ERR" ;;
    *)
      if [[ -z "$ISSUE" ]]; then ISSUE="$1"; shift
      else log_error "claim_args" "extra-arg" "unexpected argument: $1"; exit "$EX_ERR"; fi ;;
  esac
done

[[ -n "$ISSUE" ]] || { log_error "claim_args" "no-issue" "usage: auto-claim.sh <issue#>"; exit "$EX_ERR"; }
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { log_error "claim_args" "bad-issue" "issue must be a number: $ISSUE"; exit "$EX_ERR"; }
case "$WANT_KIND" in
  "$AUTO_LEASE_KIND_CLAIM"|"$AUTO_LEASE_KIND_RECLAIM") : ;;
  *) log_error "claim_args" "bad-kind" "--kind must be ${AUTO_LEASE_KIND_CLAIM} or ${AUTO_LEASE_KIND_RECLAIM}"; exit "$EX_ERR" ;;
esac
export AUTO_ISSUE="$ISSUE"

# --------------------------------------------------------------------------- #
# Stable runner identity, computed once for this process (architecture §3.2).
#   AUTO_RUNNER_ID may be pre-exported by the driver so the whole iteration
#   shares ONE identity; otherwise we mint one here.
# --------------------------------------------------------------------------- #
if [[ -z "${AUTO_RUNNER_ID:-}" ]]; then
  AUTO_RUNNER_ID="${AUTO_RUNNER_PREFIX}-$(hostname -s 2>/dev/null || echo host)-$$-$(date +%s)-${RANDOM}"
  export AUTO_RUNNER_ID
fi
readonly RUNNER_ID="$AUTO_RUNNER_ID"

# --------------------------------------------------------------------------- #
# Account resolution: every write below runs as the ACTIVE local gh account.
# gh_select_account resolves + HARD-ASSERTS (no switch), returning EX_PREFLIGHT_ACCOUNT on fail.
# --------------------------------------------------------------------------- #
gh_select_account >/dev/null || exit "$EX_PREFLIGHT_ACCOUNT"

# =========================================================================== #
# Lease-comment helpers — the lease comment is the AUTHORITATIVE lock signal.
# Marker line is machine-parseable (constants.sh AUTO_LEASE_MARKER_PREFIX):
#   <!-- auto-lease v1 runner="<id>" ttl_seconds="<n>" kind="<kind>" -->
# The lease's EFFECTIVE timestamp is the comment's server createdAt (NOT the text).
# =========================================================================== #

# _lease_marker <runner> <kind> [ttl_seconds]
_lease_marker() {
  local runner="$1" kind="$2" ttl="${3:-$AUTO_LEASE_TTL}"
  printf '%s runner="%s" ttl_seconds="%s" kind="%s" -->' \
    "$AUTO_LEASE_MARKER_PREFIX" "$runner" "$ttl" "$kind"
}

# _lease_body <runner> <kind> [ttl_seconds] [note]
#   Compose a full lease comment body (marker line + human-readable summary).
_lease_body() {
  local runner="$1" kind="$2" ttl="${3:-$AUTO_LEASE_TTL}" note="${4:-}"
  local mins=$(( ttl / 60 ))
  printf '%s\n' "$(_lease_marker "$runner" "$kind" "$ttl")"
  printf '\n'
  case "$kind" in
    "$AUTO_LEASE_KIND_RECLAIM")
      printf '🤖 /auto lease — runner `%s` RECLAIMED this issue (kind=reclaim).\n' "$runner" ;;
    *)
      printf '🤖 /auto lease — runner `%s` claimed this issue (kind=%s).\n' "$runner" "$kind" ;;
  esac
  printf 'Lease expires by server-time + %dm unless renewed. Will open exactly one PR -> %s.\n' \
    "$mins" "$AUTO_BASE_BRANCH"
  # NOTE: must not end on a bare `[[ ]] && …` — when $note is empty that returns 1, and
  # this body is captured via $(…) under `set -e`, which would abort the caller silently.
  if [[ -n "$note" ]]; then printf '%s\n' "$note"; fi
  return 0
}

# _release_marker <runner> <reason>
_release_marker() {
  printf '%s runner="%s" ttl_seconds="0" kind="%s" reason="%s" -->' \
    "$AUTO_LEASE_MARKER_PREFIX" "$1" "$AUTO_LEASE_KIND_RELEASE" "$2"
}

# _retract_lease <reason>
#   Post a release lease for THIS runner (Phase D loser path). Best-effort.
_retract_lease() {
  local reason="$1" body
  body="$(printf '%s\n\n🤖 /auto — runner `%s` retracts its lease (%s).\n' \
            "$(_release_marker "$RUNNER_ID" "$reason")" "$RUNNER_ID" "$reason")"
  gh_issue_comment "$ISSUE" "$body" >/dev/null 2>&1 \
    || log_debug "claim_retract" "retract-comment-tolerated issue=${ISSUE}"
}

# _now_epoch — local epoch seconds (TTL margins are generous, so skew is moot).
# Lease comment ISO-8601 createdAt -> epoch conversion is done inside jq
# (fromdateiso8601), so all comparisons stay on server timestamps, not local clocks.
_now_epoch() { date -u +%s; }

# =========================================================================== #
# Live-lease computation over an issue's comment set.
#
# A lease comment is any comment whose body contains the lease marker prefix.
# We extract (createdAt, runner, ttl, kind) per lease, then compute the LIVE set
# = leases whose createdAt + ttl > now. The WINNER among the live set is:
#   - if any kind=reclaim exists -> the NEWEST reclaim (supersedes expired leases);
#   - else -> the OLDEST createdAt (ties broken by lexicographic runner).
# A kind=release comment voids that runner's prior claim (the runner withdrew).
#
# Emitted via jq as TSV rows: "<epoch>\t<runner>\t<kind>" for live leases, plus a
# trailing "WINNER\t<runner>" line. All parsing is on the JSON, never the prose.
# =========================================================================== #

# _live_lease_winner <comments-json> <now-epoch>
#   Print the winning runner id of the LIVE lease set, or empty if none live.
#   Honors releases (a release by runner R after R's newest claim voids R).
_live_lease_winner() {
  local comments_json="$1" now="$2"
  printf '%s' "$comments_json" | jq -r \
    --arg prefix "$AUTO_LEASE_MARKER_PREFIX" \
    --argjson now "$now" \
    --arg release "$AUTO_LEASE_KIND_RELEASE" \
    --arg reclaim "$AUTO_LEASE_KIND_RECLAIM" '
    # Extract marker fields from a comment body, or null if not a lease comment.
    def field($k): (capture($k + "=\"(?<v>[^\"]*)\"") .v) // null;
    [ .[]
      | { createdAt, body }
      | select(.body | contains($prefix))
      | { iso: .createdAt,
          runner: (.body | field("runner")),
          ttl:    ((.body | field("ttl_seconds") | tonumber?) // 0),
          kind:   (.body | field("kind")) }
      | select(.runner != null)
    ] as $leases
    # epoch from ISO (jq fromdate handles Z-suffixed RFC3339).
    | ($leases | map(. + { epoch: (.iso | fromdateiso8601? // (.iso | sub("Z$";"+00:00") | fromdate?) // 0) })) as $L
    # For each runner, the epoch of its NEWEST release (0 if none) voids any
    # claim/renew/reclaim at or before that release.
    | ( reduce $L[] as $x ({};
          if $x.kind == $release
          then .[$x.runner] = ([ (.[$x.runner] // 0), $x.epoch ] | max)
          else . end) ) as $rel
    | [ $L[]
        | select(.kind != $release)
        | select((($rel[.runner] // 0)) < .epoch)         # not voided by a later release
        | select((.epoch + .ttl) > $now)                  # still within TTL (LIVE)
      ] as $live
    | if ($live | length) == 0 then ""
      else
        ( [ $live[] | select(.kind == $reclaim) ] ) as $rc
        | ( if ($rc | length) > 0
            then ($rc | sort_by(.epoch) | last)            # newest reclaim supersedes
            else ($live | sort_by([.epoch, .runner]) | first)  # oldest createdAt, tie by runner
            end )
        | .runner
      end
  ' 2>/dev/null || true
}

# _newest_lease_epoch <comments-json>
#   Print the createdAt epoch of the NEWEST lease comment of kind claim|renew|
#   reclaim (ignoring releases), or empty if none. Used by stale-reclaim precheck.
_newest_lease_epoch() {
  local comments_json="$1"
  printf '%s' "$comments_json" | jq -r \
    --arg prefix "$AUTO_LEASE_MARKER_PREFIX" \
    --arg release "$AUTO_LEASE_KIND_RELEASE" '
    def field($k): (capture($k + "=\"(?<v>[^\"]*)\"") .v) // null;
    [ .[]
      | { createdAt, body }
      | select(.body | contains($prefix))
      | { kind: (.body | field("kind")),
          epoch: (.createdAt | fromdateiso8601? // (.createdAt | sub("Z$";"+00:00") | fromdate?) // 0) }
      | select(.kind != $release)
    ]
    | if length == 0 then "" else (max_by(.epoch).epoch | tostring) end
  ' 2>/dev/null || true
}

# _has_open_pr_for_issue <issue#>
#   True (0) iff an OPEN PR targeting develop-auto references "Closes #N" in body.
#   This is the eventually-consistent advisory check; combined with the TTL check
#   it gates stale reclaim (architecture §3.2 — the head-branch existence check is
#   the strongly-consistent guard used at PR-create time; here we only need "is
#   work still in flight", for which the open-PR body search is sufficient).
_has_open_pr_for_issue() {
  local n="$1" found
  found="$(gh_retry gh.pr_for_issue -- pr list --base "$AUTO_BASE_BRANCH" --state open \
            --search "in:body \"Closes #${n}\"" --json number --jq '.[0].number // empty' \
            2>/dev/null || true)"
  [[ -n "$found" ]]
}

# _labels_csv <issue-json> -> comma-joined label names (for predicate checks).
_labels_csv() {
  printf '%s' "$1" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || true
}
_has_label() { case ",$1," in *,"$2",*) return 0 ;; *) return 1 ;; esac; }

# =========================================================================== #
# PHASE A — gate. One read; classify claimability.
# =========================================================================== #
log_info "claim_start" "runner=${RUNNER_ID} kind=${WANT_KIND}"

ISSUE_JSON="$(gh_issue_view "$ISSUE" "number,state,labels,assignees,comments,createdAt")" || {
  log_error "claim_read" "issue-read-failed" "issue=${ISSUE}"; exit "$EX_NOT_CLAIMABLE"; }

STATE="$(printf '%s' "$ISSUE_JSON" | jq -r '.state' 2>/dev/null || true)"
LABELS_CSV="$(_labels_csv "$ISSUE_JSON")"
COMMENTS_JSON="$(printf '%s' "$ISSUE_JSON" | jq -c '.comments' 2>/dev/null || echo '[]')"

if [[ "$STATE" != "OPEN" ]]; then
  log_info "claim_not_claimable" "issue=${ISSUE} state=${STATE} (not OPEN)"
  exit "$EX_NOT_CLAIMABLE"
fi
if _has_label "$LABELS_CSV" "$AUTO_LABEL_STOP" \
   || _has_label "$LABELS_CSV" "$AUTO_LABEL_HOLD" \
   || _has_label "$LABELS_CSV" "$AUTO_LABEL_STATUS_BLOCKED"; then
  log_info "claim_not_claimable" "issue=${ISSUE} carries stop/hold/blocked label"
  exit "$EX_NOT_CLAIMABLE"
fi

# Determine eligibility path: eligible label, OR stale-reclaimable.
NOW="$(_now_epoch)"
RECLAIMABLE=0
NEWEST_EPOCH="$(_newest_lease_epoch "$COMMENTS_JSON")"
if [[ -n "$NEWEST_EPOCH" ]]; then
  AGE=$(( NOW - NEWEST_EPOCH ))
  if (( AGE > AUTO_LEASE_TTL )) && ! _has_open_pr_for_issue "$ISSUE"; then
    RECLAIMABLE=1
  fi
fi
# Orphaned claim: auto:claimed / status:in-progress present but NO lease comment at all
# (a claim that crashed between add-label and post-lease — additive writes are not atomic,
# and auto-claim has no self-cleanup trap). With no open PR, such an issue would otherwise
# be stuck forever (not eligible, no stale lease to reclaim). Treat it as reclaimable.
if [[ -z "$NEWEST_EPOCH" ]] \
   && { _has_label "$LABELS_CSV" "$AUTO_LABEL_CLAIMED" || _has_label "$LABELS_CSV" "$AUTO_LABEL_STATUS_IN_PROGRESS"; } \
   && ! _has_open_pr_for_issue "$ISSUE"; then
  RECLAIMABLE=1
fi

if _has_label "$LABELS_CSV" "$AUTO_LABEL_ELIGIBLE"; then
  : # claimable via the normal eligibility path.
elif (( RECLAIMABLE == 1 )); then
  # Only claimable via stale-reclaim -> force reclaim semantics.
  WANT_KIND="$AUTO_LEASE_KIND_RECLAIM"
  log_info "claim_reclaim_path" "issue=${ISSUE} stale lease (age>${AUTO_LEASE_TTL}s, no open PR) -> reclaim"
else
  log_info "claim_not_claimable" "issue=${ISSUE} not ${AUTO_LABEL_ELIGIBLE} and not stale-reclaimable"
  exit "$EX_NOT_CLAIMABLE"
fi

# =========================================================================== #
# PHASE B — stale pre-check. If a LIVE lease is held by someone else, lose early
# (unless we are explicitly reclaiming, in which case a reclaim lease supersedes).
# =========================================================================== #
LIVE_WINNER="$(_live_lease_winner "$COMMENTS_JSON" "$NOW")"
if [[ -n "$LIVE_WINNER" && "$LIVE_WINNER" != "$RUNNER_ID" && "$WANT_KIND" != "$AUTO_LEASE_KIND_RECLAIM" ]]; then
  log_info "claim_lost_precheck" "issue=${ISSUE} live lease held by ${LIVE_WINNER}"
  exit "$EX_CLAIM_LOST"
fi

# =========================================================================== #
# PHASE C — write the claim. ADDITIVE only (cannot clobber a racing winner).
#   1. label: +auto:claimed, -auto:eligible
#   2. lease comment {runner,kind,ttl,createdAt(server)}
#   3. assignee: + the active gh account (best-effort, cosmetic)
# =========================================================================== #
NOTE=""
[[ "$WANT_KIND" == "$AUTO_LEASE_KIND_RECLAIM" && -n "$LIVE_WINNER" && "$LIVE_WINNER" != "$RUNNER_ID" ]] \
  && NOTE="Superseding stale lease previously held by \`${LIVE_WINNER}\`."

gh_issue_add_labels "$ISSUE" "$AUTO_LABEL_CLAIMED" \
  || { log_error "claim_label" "add-claimed-failed" "issue=${ISSUE}"; exit "$EX_ERR"; }
gh_issue_remove_labels "$ISSUE" "$AUTO_LABEL_ELIGIBLE" || true

LEASE_BODY="$(_lease_body "$RUNNER_ID" "$WANT_KIND" "$AUTO_LEASE_TTL" "$NOTE")"
if ! gh_issue_comment "$ISSUE" "$LEASE_BODY" >/dev/null; then
  log_error "claim_lease" "lease-comment-failed" "issue=${ISSUE}"
  exit "$EX_ERR"
fi
gh_issue_add_assignee "$ISSUE" "$AUTO_GH_ACCOUNT" || true
log_info "claim_wrote" "issue=${ISSUE} posted ${WANT_KIND} lease for ${RUNNER_ID}"

# =========================================================================== #
# PHASE D — confirm by RE-READ (the CAS emulation). Jitter so racing writers'
# comments both land before we read; then apply the deterministic tie-break.
# =========================================================================== #
JITTER=$(( RANDOM % (AUTO_CLAIM_JITTER_MAX - AUTO_CLAIM_JITTER_MIN + 1) + AUTO_CLAIM_JITTER_MIN ))
log_debug "claim_jitter" "sleeping ${JITTER}s before confirm re-read"
sleep "$JITTER"

RE_JSON="$(gh_issue_view "$ISSUE" "comments")" || {
  log_error "claim_confirm_read" "reread-failed" "issue=${ISSUE}"; exit "$EX_ERR"; }
RE_COMMENTS="$(printf '%s' "$RE_JSON" | jq -c '.comments' 2>/dev/null || echo '[]')"

NOW2="$(_now_epoch)"
WINNER="$(_live_lease_winner "$RE_COMMENTS" "$NOW2")"

if [[ "$WINNER" == "$RUNNER_ID" ]]; then
  # WE WON: advance lifecycle to status:in-progress (keep auto:claimed as the lock label).
  gh_issue_add_labels "$ISSUE" "$AUTO_LABEL_STATUS_IN_PROGRESS" || true
  gh_issue_remove_labels "$ISSUE" "$AUTO_LABEL_STATUS_READY" || true
  log_info "claim_won" "issue=${ISSUE} runner=${RUNNER_ID} kind=${WANT_KIND}"
  printf '%s\n' "$RUNNER_ID"
  exit "$EX_OK"
fi

# We LOST the deterministic tie-break (or our lease never landed). Retract ours,
# restore eligibility ONLY if no other runner is the current winner (so we don't
# strip a winner's queue state — the winner already moved it to in-progress, and
# auto:claimed remains). The winner's lease is left intact.
log_info "claim_lost_confirm" "issue=${ISSUE} winner=${WINNER:-none} != ${RUNNER_ID}; retracting"
_retract_lease "lost-race"
# If NOBODY is a live winner (e.g. all leases somehow expired in the jitter window),
# put the issue back on the queue so it is not orphaned in auto:claimed.
if [[ -z "$WINNER" ]]; then
  gh_issue_add_labels "$ISSUE" "$AUTO_LABEL_ELIGIBLE" || true
  gh_issue_remove_labels "$ISSUE" "$AUTO_LABEL_CLAIMED" || true
  gh_issue_remove_assignee "$ISSUE" "$AUTO_GH_ACCOUNT" || true
fi
exit "$EX_CLAIM_LOST"
