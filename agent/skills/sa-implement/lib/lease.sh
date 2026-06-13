#!/usr/bin/env bash
# shellcheck shell=bash
#
# lease.sh — shared per-issue LEASE-COMMENT parsing for /auto (the single home of the
# lease-marker field extractor + live-lease / newest-lease / owner computations).
#
# A "lease comment" is any issue comment whose body contains AUTO_LEASE_MARKER_PREFIX.
# Its machine-parseable marker line carries `key="value"` fields ({runner, kind, ttl,
# ...}); the human prose below the marker is NEVER parsed. All staleness math runs on
# the SERVER `createdAt` timestamp (converted to epoch inside jq via fromdateiso8601),
# so it is immune to local clock skew (state-model §4 / decisions.md §4).
#
# Before this lib existed the same `def field($k): capture(...)` extractor and the
# live/newest/owner jq were copy-pasted across auto-claim.sh, auto-stale.sh, and
# auto-iterate.sh (near-identical copies — review finding).
# Centralizing it here removes that duplication and keeps the lease semantics in ONE
# auditable place. Pure jq over the comments JSON; no network, no git, no gh.
#
# Public API (all take the comments JSON exactly as gh_issue_comments_json prints it —
# a JSON array of {author, createdAt, body} — on $1):
#
#   lease_live_owner   <comments-json> [now-epoch]   -> winning live-lease runner | ""
#   lease_newest_owner <comments-json>               -> runner of newest non-release | ""
#   lease_newest_epoch <comments-json>               -> createdAt epoch of newest | ""
#   lease_owned_by     <comments-json> <runner> [now-epoch]  -> exit 0 if that runner
#                                                              holds the live lease.
#
# "Live" = within TTL and not voided by a later release. The WINNER among live leases:
#   - if any kind=reclaim is live  -> the NEWEST reclaim supersedes (stale takeover);
#   - else                         -> the OLDEST createdAt (deterministic race tie-break,
#                                      ties broken lexicographically by runner id).
# A kind=release by runner R after R's newest claim withdraws R from contention.
#
# Depends ONLY on: jq (+ constants.sh for the markers/kinds). Sourced, never executed.
#
set -euo pipefail

# Source constants defensively so this lib works regardless of source order.
if [[ -z "${AUTO_CONSTANTS_SOURCED:-}" ]]; then
  # shellcheck source=constants.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/constants.sh"
fi

if [[ -n "${AUTO_LEASE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly AUTO_LEASE_SOURCED=1

# --------------------------------------------------------------------------- #
# _lease_now_epoch — local epoch seconds. Lease createdAt -> epoch is done inside
# jq (server timestamps), so this is only the "now" reference for TTL margins, which
# are generous enough that local skew is moot.
# --------------------------------------------------------------------------- #
_lease_now_epoch() { date -u +%s; }

# --------------------------------------------------------------------------- #
# lease_live_owner <comments-json> [now-epoch]
#   Print the winning runner id of the LIVE lease set, or empty if none is live.
#   Honors releases (a release by runner R after R's newest claim voids R) and the
#   reclaim-supersedes / oldest-wins tie-break. Mirrors auto-claim.sh's _live_lease_winner.
# --------------------------------------------------------------------------- #
lease_live_owner() {
  local comments_json="$1" now="${2:-}"
  [[ -n "$now" ]] || now="$(_lease_now_epoch)"
  printf '%s' "$comments_json" | jq -r \
    --arg prefix "$AUTO_LEASE_MARKER_PREFIX" \
    --argjson now "$now" \
    --arg release "$AUTO_LEASE_KIND_RELEASE" \
    --arg reclaim "$AUTO_LEASE_KIND_RECLAIM" '
    # Extract a marker field ("key=\"value\"") from a comment body, or null.
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
    | ($leases | map(. + { epoch: (.iso | fromdateiso8601? // (.iso | sub("Z$";"+00:00") | fromdate?) // 0) })) as $L
    # Per runner, the epoch of its NEWEST release voids any claim at/before it.
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

# --------------------------------------------------------------------------- #
# lease_owned_by <comments-json> <runner> [now-epoch]
#   Exit 0 (true) iff <runner> is the winning live-lease holder; non-zero otherwise.
#   This is the cold-start resume predicate ("do I still own this issue?").
# --------------------------------------------------------------------------- #
lease_owned_by() {
  local comments_json="$1" runner="${2:?lease_owned_by: runner required}" now="${3:-}"
  local owner
  owner="$(lease_live_owner "$comments_json" "$now")"
  [[ -n "$runner" && "$owner" == "$runner" ]]
}

# --------------------------------------------------------------------------- #
# lease_newest_epoch <comments-json>
#   Print the createdAt epoch of the NEWEST lease comment of kind claim|renew|reclaim
#   (releases ignored), or empty if none. Used by stale-reclaim / watchdog age checks.
# --------------------------------------------------------------------------- #
lease_newest_epoch() {
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

# --------------------------------------------------------------------------- #
# lease_newest_owner <comments-json>
#   Print the runner id of the NEWEST non-release lease comment, or empty if none.
#   Used to identify the (possibly dead) runner that last held a stale lease.
# --------------------------------------------------------------------------- #
lease_newest_owner() {
  local comments_json="$1"
  printf '%s' "$comments_json" | jq -r \
    --arg prefix "$AUTO_LEASE_MARKER_PREFIX" \
    --arg release "$AUTO_LEASE_KIND_RELEASE" '
    def field($k): (capture($k + "=\"(?<v>[^\"]*)\"") .v) // null;
    [ .[]
      | { createdAt, body }
      | select(.body | contains($prefix))
      | { runner: (.body | field("runner")),
          kind:   (.body | field("kind")),
          epoch:  (.createdAt | fromdateiso8601? // (.createdAt | sub("Z$";"+00:00") | fromdate?) // 0) }
      | select(.kind != $release)
      | select(.runner != null)
    ]
    | if length == 0 then "" else (max_by(.epoch).runner) end
  ' 2>/dev/null || true
}
