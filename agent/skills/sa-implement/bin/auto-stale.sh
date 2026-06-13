#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-stale.sh — scan for dead leases and reclaim the work (decisions.md §4).
#
# A claimed issue whose lease is past TTL with NO open PR almost certainly means
# its runner died (a live L/XL runner renews its lease at TTL/2 via a heartbeat,
# so a missed heartbeat == dead runner). This scanner finds such issues and
# RECLAIMS them so the backlog keeps moving; everything else is SKIPPED.
#
# An issue is RECLAIMABLE iff ALL hold (architecture §3.2):
#   1. it is OPEN and carries auto:claimed and/or status:in-progress, AND
#   2. it does NOT carry auto:hold / auto:stop / status:blocked, AND
#   3. its NEWEST lease comment (kind claim|renew|reclaim) is older than
#      AUTO_LEASE_TTL by server createdAt, AND
#   4. there is NO open PR targeting develop-auto for the issue ("Closes #N").
#
# Reclaim DELEGATES to the single canonical claim path:
#       auto-claim.sh <N> --kind reclaim
# which posts a kind=reclaim lease that SUPERSEDES the expired one (a revived dead
# runner can never win the tie-break because its expired lease is not in the live
# set). On a won reclaim the issue is re-driven by the caller; auto-stale.sh only
# performs the takeover and reports which issues it reclaimed.
#
# All gh operations run as the installing user's ACTIVE local gh account
# (resolved at runtime, never via `gh auth switch`); identity drift is HARD-REFUSED.
# git+gh ONLY. Read-mostly + bounded writes; safe to run repeatedly (idempotent:
# a non-stale lease is skipped, an already-reclaimed issue is held by THIS runner).
#
# Usage:
#   auto-stale.sh [--dry-run] [--limit N] [--reclaim] [--quiet]
#
#   --dry-run   report what WOULD be reclaimed; perform NO writes (overrides --reclaim).
#   --limit N   cap the number of claimed issues scanned (default 200).
#   --reclaim   actually take over stale leases (default). With neither --reclaim
#               nor --dry-run, the default is to reclaim.
#   --no-reclaim report-only (like --dry-run but still labeled a live scan in logs).
#   --quiet     suppress the per-issue stdout report lines (still logs).
#
# Output (stdout): one line per scanned stale candidate:
#       RECLAIMED <N> <runner>     (took over)
#       LOST      <N>              (reclaim raced and lost)
#       SKIP      <N> <why>        (not stale / has PR / not claimable)
#   then a trailing summary line:  SUMMARY scanned=<a> reclaimed=<b> skipped=<c>
#
# Exit codes (decisions.md §6):
#   0   scan complete (regardless of how many were reclaimed).
#   69  gh account could not be resolved, or drifted from the run identity.
#   1   generic / argument error / could not list claimed issues.
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_SELF_DIR}/../lib/constants.sh"
# shellcheck source=../lib/log.sh
source "${_SELF_DIR}/../lib/log.sh"
# shellcheck source=../lib/gh.sh
source "${_SELF_DIR}/../lib/gh.sh"

export AUTO_PHASE="${AUTO_PHASE:-stale}"

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
DRY_RUN=0
DO_RECLAIM=1
LIMIT=200
QUIET=0

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --reclaim)    DO_RECLAIM=1; shift ;;
    --no-reclaim) DO_RECLAIM=0; shift ;;
    --limit)      LIMIT="${2:?--limit requires a number}"; shift 2 ;;
    --quiet)      QUIET=1; shift ;;
    -h|--help)    print_help ;;
    *) log_error "stale_args" "unknown-arg" "unknown argument: $1"; exit "$EX_ERR" ;;
  esac
done
[[ "$LIMIT" =~ ^[0-9]+$ ]] || { log_error "stale_args" "bad-limit" "--limit must be a number: $LIMIT"; exit "$EX_ERR"; }
(( DRY_RUN == 1 )) && DO_RECLAIM=0

# --------------------------------------------------------------------------- #
# Account resolution — reads are fine on any account, but reclaim
# writes (and the assignee on takeover) must be the resolved run account, so resolve up front.
# --------------------------------------------------------------------------- #
gh_select_account >/dev/null || exit "$EX_PREFLIGHT_ACCOUNT"

# --------------------------------------------------------------------------- #
# Helpers (shared spelling with auto-claim.sh; lease parsing is on JSON, never prose).
# --------------------------------------------------------------------------- #
_now_epoch() { date -u +%s; }
_has_label() { case ",$1," in *,"$2",*) return 0 ;; *) return 1 ;; esac; }

_report() { (( QUIET == 1 )) || printf '%s\n' "$*"; }

# Newest lease epoch (kind claim|renew|reclaim) from a comments JSON array; empty
# if no lease comment exists. (A release does not count as a live lease anchor.)
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

# Newest lease runner id (for reporting which dead runner we superseded).
_newest_lease_runner() {
  local comments_json="$1"
  printf '%s' "$comments_json" | jq -r \
    --arg prefix "$AUTO_LEASE_MARKER_PREFIX" \
    --arg release "$AUTO_LEASE_KIND_RELEASE" '
    def field($k): (capture($k + "=\"(?<v>[^\"]*)\"") .v) // null;
    [ .[]
      | { createdAt, body }
      | select(.body | contains($prefix))
      | { runner: (.body | field("runner")),
          kind: (.body | field("kind")),
          epoch: (.createdAt | fromdateiso8601? // (.createdAt | sub("Z$";"+00:00") | fromdate?) // 0) }
      | select(.kind != $release)
    ]
    | if length == 0 then "" else (max_by(.epoch).runner // "") end
  ' 2>/dev/null || true
}

# True (0) iff an OPEN PR targeting develop-auto references "Closes #N".
_has_open_pr_for_issue() {
  local n="$1" found
  found="$(gh_retry gh.pr_for_issue -- pr list --base "$AUTO_BASE_BRANCH" --state open \
            --search "in:body \"Closes #${n}\"" --json number --jq '.[0].number // empty' \
            2>/dev/null || true)"
  [[ -n "$found" ]]
}

# --------------------------------------------------------------------------- #
# Build the candidate set: OPEN issues carrying auto:claimed OR status:in-progress.
# gh has no OR across --label, so query both label sets and union by number.
# --------------------------------------------------------------------------- #
log_info "stale_start" "scanning claimed/in-progress issues (dry_run=${DRY_RUN} reclaim=${DO_RECLAIM} limit=${LIMIT})"

claimed_json="$(gh_retry gh.stale_claimed -- issue list --state open \
                  --label "$AUTO_LABEL_CLAIMED" --limit "$LIMIT" \
                  --json number,labels 2>/dev/null || echo '[]')"
inprog_json="$(gh_retry gh.stale_inprog -- issue list --state open \
                  --label "$AUTO_LABEL_STATUS_IN_PROGRESS" --limit "$LIMIT" \
                  --json number,labels 2>/dev/null || echo '[]')"

CANDIDATES="$(jq -rn --argjson a "$claimed_json" --argjson b "$inprog_json" \
  '($a + $b) | map(.number) | unique | .[]' 2>/dev/null || true)"

if [[ -z "$CANDIDATES" ]]; then
  log_info "stale_none" "no claimed/in-progress issues to scan"
  _report "SUMMARY scanned=0 reclaimed=0 skipped=0"
  exit "$EX_OK"
fi

scanned=0 reclaimed=0 skipped=0
NOW="$(_now_epoch)"

for n in $CANDIDATES; do
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  scanned=$(( scanned + 1 ))
  export AUTO_ISSUE="$n"

  ij="$(gh_issue_view "$n" "number,state,labels,comments" 2>/dev/null || echo '{}')"
  state="$(printf '%s' "$ij" | jq -r '.state // ""' 2>/dev/null || true)"
  labels_csv="$(printf '%s' "$ij" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || true)"
  comments="$(printf '%s' "$ij" | jq -c '.comments // []' 2>/dev/null || echo '[]')"

  # Condition 1/2: open + not held/stopped/blocked.
  if [[ "$state" != "OPEN" ]]; then
    skipped=$(( skipped + 1 )); _report "SKIP ${n} not-open"; continue
  fi
  if _has_label "$labels_csv" "$AUTO_LABEL_HOLD" \
     || _has_label "$labels_csv" "$AUTO_LABEL_STOP" \
     || _has_label "$labels_csv" "$AUTO_LABEL_STATUS_BLOCKED"; then
    skipped=$(( skipped + 1 )); _report "SKIP ${n} held/stopped/blocked"; continue
  fi

  # Condition 3: lease past TTL.
  newest="$(_newest_lease_epoch "$comments")"
  if [[ -z "$newest" ]]; then
    # auto:claimed with no lease comment at all -> orphaned label; treat as stale.
    log_debug "stale_orphan" "issue=${n} claimed label but no lease comment"
    age=$(( AUTO_LEASE_TTL + 1 ))
  else
    age=$(( NOW - newest ))
  fi
  if (( age <= AUTO_LEASE_TTL )); then
    skipped=$(( skipped + 1 ))
    _report "SKIP ${n} lease-fresh age=${age}s ttl=${AUTO_LEASE_TTL}s"
    continue
  fi

  # Condition 4: no open PR for the issue.
  if _has_open_pr_for_issue "$n"; then
    skipped=$(( skipped + 1 ))
    _report "SKIP ${n} has-open-pr"
    log_info "stale_skip_pr" "issue=${n} stale lease but an open PR exists; leaving to review"
    continue
  fi

  dead_runner="$(_newest_lease_runner "$comments")"
  log_info "stale_candidate" "issue=${n} reclaimable (lease age=${age}s > ttl=${AUTO_LEASE_TTL}s, no PR, dead_runner=${dead_runner:-unknown})"

  if (( DO_RECLAIM == 0 )); then
    _report "SKIP ${n} would-reclaim age=${age}s dead_runner=${dead_runner:-unknown}"
    continue
  fi

  # Delegate the actual takeover to the single canonical claim path (kind=reclaim).
  rc=0
  won_runner="$("${_SELF_DIR}/auto-claim.sh" "$n" --kind "$AUTO_LEASE_KIND_RECLAIM" 2>/dev/null)" || rc=$?
  case "$rc" in
    0)
      reclaimed=$(( reclaimed + 1 ))
      _report "RECLAIMED ${n} ${won_runner}"
      log_info "stale_reclaimed" "issue=${n} reclaimed by ${won_runner}" ;;
    "$EX_CLAIM_LOST")
      skipped=$(( skipped + 1 ))
      _report "LOST ${n}"
      log_info "stale_reclaim_lost" "issue=${n} reclaim raced and lost (another runner is live)" ;;
    "$EX_NOT_CLAIMABLE")
      skipped=$(( skipped + 1 ))
      _report "SKIP ${n} not-claimable"
      log_info "stale_reclaim_skip" "issue=${n} became not-claimable during reclaim" ;;
    *)
      skipped=$(( skipped + 1 ))
      _report "SKIP ${n} reclaim-error-rc=${rc}"
      log_error "stale_reclaim_error" "reclaim-rc-${rc}" "issue=${n}" ;;
  esac
done

unset AUTO_ISSUE
log_info "stale_done" "scanned=${scanned} reclaimed=${reclaimed} skipped=${skipped}"
_report "SUMMARY scanned=${scanned} reclaimed=${reclaimed} skipped=${skipped}"
exit "$EX_OK"
