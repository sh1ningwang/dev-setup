#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # every constant here is consumed by the bin/* and lib/* files that source this.
#
# constants.sh — single source of truth for /auto shared constants.
#
# Sourced (never executed) by every bin/*.sh and lib/*.sh. Defines branch policy,
# account identity, label taxonomy, exit codes, timing/concurrency bounds, cache
# paths and log-path patterns. The values here are authoritative; decisions.md §3
# (labels) and §6 (exit codes) are mirrored EXACTLY, and templates/.github/auto/
# labels.json MUST agree with the label constants below.
#
# Idempotent: guarded so repeated sourcing is a no-op and `readonly` never errors.
#
# Conventions:
#   - readonly for values that must never change within a run.
#   - plain assignment with ${VAR:-default} for values an operator/auto.config.json
#     may legitimately override via the environment before sourcing.
#
set -euo pipefail

# Guard against double-sourcing (readonly re-assignment would abort under set -e).
if [[ -n "${AUTO_CONSTANTS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly AUTO_CONSTANTS_SOURCED=1

# --------------------------------------------------------------------------- #
# 0. Versioning
# --------------------------------------------------------------------------- #
readonly AUTO_VERSION="2.0.0"          # /auto engine release line (sa-design + sa-implement)
readonly AUTO_SCHEMA_VERSION=1         # state.json / config.json / comment marker schema

# --------------------------------------------------------------------------- #
# 1. Branch policy (decisions.md D1, D2; HARD LOCK — never overridable by args)
# --------------------------------------------------------------------------- #
readonly AUTO_BASE_BRANCH="develop-auto"   # EVERY /auto PR targets ONLY this branch.
readonly PARITY_REF_BRANCH="develop"       # CI on develop-auto must mirror this branch.
readonly AUTO_MERGE_METHOD="squash"        # one issue -> one PR -> one atomic commit.

# Branch naming: auto/<type>/<issue#>-<slug>. <slug> lowercased, non-alnum -> '-', <= this.
readonly AUTO_BRANCH_PREFIX="auto"
readonly AUTO_SLUG_MAXLEN=40
# Allowed <type> tokens in branch names (map to type:* labels; see AUTO_LABEL_TYPE_*).
readonly AUTO_BRANCH_TYPES="feat fix chore spike refactor docs"

# Force-push is FORBIDDEN everywhere (decisions.md §2). Conflict resolution uses
# `gh pr update-branch` (merge-from-base) exclusively. This flag exists only so code
# can assert it and refuse; it is never flipped on in v1.
readonly AUTO_ALLOW_FORCE_PUSH=0

# --------------------------------------------------------------------------- #
# 2. Account identity — FOLLOWS THE LOCAL gh LOGIN (no hardcoded account)
# --------------------------------------------------------------------------- #
# All git/gh operations run as whatever account is ACTIVE in the installing
# user's local `gh` CLI (`gh auth status` / `gh api user`). The engine NEVER
# runs `gh auth switch` and never mutates global gh/git state — that is what
# makes multiple concurrent loop instances (one per project directory) safe.
#
# AUTO_GH_ACCOUNT is resolved AT RUNTIME by lib/gh.sh::gh_select_account (and
# preflight A10) from the active gh login, then cached per process and in
# .auto/.account for mid-run drift detection. An operator MAY export
# AUTO_GH_ACCOUNT before launch to pin a specific authenticated account: the
# engine then HARD-ASSERTS the active login matches and aborts otherwise — it
# still never switches accounts itself.
: "${AUTO_GH_ACCOUNT:=}"            # empty = resolve from the active local gh login.
export AUTO_GH_ACCOUNT

# git author/committer identity. Empty (the default) = respect the user's own
# git config (local then global). Only when git has NO identity configured does
# the engine derive a GitHub noreply identity from the active gh account
# ("<id>+<login>@users.noreply.github.com") so commits still attribute to the
# installing user. Operators may override either value via the environment.
: "${AUTO_GIT_USER_NAME:=}"
: "${AUTO_GIT_USER_EMAIL:=}"
export AUTO_GIT_USER_NAME AUTO_GIT_USER_EMAIL

# Second-approver credential (only used IF develop-auto ever requires reviews, which
# decisions.md D6 says it must NOT). Reserved for the documented fallback path; v1
# preflight A6 aborts rather than relying on it. Env/keychain ONLY — never committed.
# AUTO_APPROVER_TOKEN is intentionally NOT defaulted here (absence is meaningful).

# --------------------------------------------------------------------------- #
# 3. Stop conditions / run ceilings (decisions.md D7 — NO cost ceiling in v1)
# --------------------------------------------------------------------------- #
# v1 stop conditions: --duration/--until, --max-prs, backlog-empty, kill-switch,
# explicit stop. --max-cost / --max-tokens flag NAMES are reserved but no-op in v1.
readonly AUTO_MAX_PRS_DEFAULT=0            # 0 = unlimited (rely on time/backlog/kill).
readonly AUTO_MAX_COST_DEFAULT=0           # reserved, no-op in v1.
readonly AUTO_MAX_TOKENS_DEFAULT=0         # reserved, no-op in v1.

# Escalation ceiling (decisions.md §2): hard-stop the run if escalation chains spike.
readonly MAX_ESCALATIONS=5

# --------------------------------------------------------------------------- #
# 4. Concurrency & leasing (decisions.md D8, §4)
# --------------------------------------------------------------------------- #
# --concurrency N parallelizes ISSUES (each its own lease+worktree+branch+PR).
# Default N=1. Subagent fan-out within an issue is always flat/depth-1 (separate).
readonly AUTO_CONCURRENCY_DEFAULT=1

# Per-issue lease TTL. Heartbeat (renew) is posted at TTL/2 for long L/XL issues.
readonly AUTO_LEASE_TTL=1800                # seconds (30 min).
readonly AUTO_LEASE_HEARTBEAT=900           # seconds (TTL/2); renew before expiry.
# Jitter window (seconds) for the claim re-read tie-break (CAS emulation).
readonly AUTO_CLAIM_JITTER_MIN=1
readonly AUTO_CLAIM_JITTER_MAX=3

# Lease comment kinds (machine-parseable marker; see references/interfaces.md).
readonly AUTO_LEASE_KIND_CLAIM="claim"
readonly AUTO_LEASE_KIND_RENEW="renew"
readonly AUTO_LEASE_KIND_RECLAIM="reclaim"
readonly AUTO_LEASE_KIND_RELEASE="release"
readonly AUTO_LEASE_KIND_DONE="done-pr"

# Runner identity prefix; full id is computed once per process at startup as
#   "${AUTO_RUNNER_PREFIX}-$(hostname -s)-$$-$(date +%s)-${RANDOM}".
readonly AUTO_RUNNER_PREFIX="auto"

# --------------------------------------------------------------------------- #
# 5. CI checks: poll cadence, flaky budget, green floor (decisions.md D2, D3)
# --------------------------------------------------------------------------- #
readonly CHECK_POLL_INTERVAL=30             # seconds between required-check polls.
readonly CHECK_POLL_TIMEOUT=3600            # seconds, hard ceiling per PR, then escalate.
readonly FLAKY_RETRY_MAX=2                  # bounded reruns of ONLY failed required checks.

# GREEN FLOOR (decisions.md D3 / architecture §2.3): refuse to merge if the
# develop-auto required-check set is EMPTY. 1 = enforce (never disable in v1).
readonly AUTO_GREEN_FLOOR=1

# --------------------------------------------------------------------------- #
# 6. Review-round bounds per size (decisions.md §2; auto.config.json may override)
# --------------------------------------------------------------------------- #
readonly AUTO_ROUNDS_S=1
readonly AUTO_ROUNDS_M=2
readonly AUTO_ROUNDS_L=3
readonly AUTO_ROUNDS_XL=3
readonly AUTO_ROUNDS_CEILING=5              # hard ceiling regardless of flag/config.
# Missing/ambiguous size routes to L (fail-safe toward more review; architecture §5.1).
readonly AUTO_SIZE_DEFAULT="L"

# --------------------------------------------------------------------------- #
# 7. Kill-switch (decisions.md §4 — single canonical contract)
# --------------------------------------------------------------------------- #
# PRIMARY  : label auto:stop on the pinned #auto-control issue.
# FALLBACK : file .auto/STOP on develop-auto (read remotely via gh api contents).
# Either signal => stop. Result cached AUTO_KILL_POLL_CACHE seconds per process.
readonly AUTO_KILL_POLL_CACHE=20            # seconds; bounds API calls under concurrency.
readonly AUTO_STOP_FILE_PATH=".auto/STOP"   # path on develop-auto for the fallback signal.

# The pinned, repo-global control issue: located-or-created (idempotent) by preflight.
# Identified by this HTML-comment marker in its body (title may vary).
readonly AUTO_CONTROL_MARKER="<!-- auto-control v1 -->"
readonly AUTO_CONTROL_TITLE="auto-control"  # canonical title for the pinned control issue.

# Per-run status dashboard issue (transient): identified by this marker + run id.
readonly AUTO_STATUS_MARKER="<!-- auto-status v1 -->"

# --------------------------------------------------------------------------- #
# 8. Marker lines for machine-parseable issue comments (see interfaces.md schemas)
# --------------------------------------------------------------------------- #
readonly AUTO_LEASE_MARKER_PREFIX="<!-- auto-lease v1"        # lease comment marker.
readonly AUTO_SEED_FP_PREFIX="<!-- auto-seed-fp:"            # seed dedup fingerprint marker.
readonly AUTO_ESCALATION_MARKER_PREFIX="<!-- auto-escalation v1"  # human-gated escalation marker (idempotent dedup).

# --------------------------------------------------------------------------- #
# 9. LABEL TAXONOMY (decisions.md §3 — THE single string source of truth)
#    templates/.github/auto/labels.json MUST match these names EXACTLY.
#    Do NOT introduce auto:queued / auto:in-progress / auto:blocked / size/* etc.
# --------------------------------------------------------------------------- #

# Control plane (auto:*) — autonomy state.
readonly AUTO_LABEL_ELIGIBLE="auto:eligible"   # /auto MAY pick this issue.
readonly AUTO_LABEL_CLAIMED="auto:claimed"     # a lease is held (paired w/ lease comment + assignee).
readonly AUTO_LABEL_HOLD="auto:hold"           # human-gated; /auto must NOT pick (escalations).
readonly AUTO_LABEL_STOP="auto:stop"           # kill-switch (on the pinned #auto-control issue ONLY).
readonly AUTO_LABEL_SEEDED="auto:seeded"       # issue filed by --seed.

# Lifecycle (status:*).
readonly AUTO_LABEL_STATUS_TRIAGE="status:triage"
readonly AUTO_LABEL_STATUS_READY="status:ready"
readonly AUTO_LABEL_STATUS_IN_PROGRESS="status:in-progress"
readonly AUTO_LABEL_STATUS_IN_REVIEW="status:in-review"
readonly AUTO_LABEL_STATUS_DONE="status:done"
readonly AUTO_LABEL_STATUS_BLOCKED="status:blocked"   # failed/blocked, needs human.

# Priority (P0 highest).
readonly AUTO_LABEL_PRIORITY_P0="priority:P0"
readonly AUTO_LABEL_PRIORITY_P1="priority:P1"
readonly AUTO_LABEL_PRIORITY_P2="priority:P2"
readonly AUTO_LABEL_PRIORITY_P3="priority:P3"

# Type.
readonly AUTO_LABEL_TYPE_FEATURE="type:feature"
readonly AUTO_LABEL_TYPE_BUG="type:bug"
readonly AUTO_LABEL_TYPE_CHORE="type:chore"
readonly AUTO_LABEL_TYPE_SPIKE="type:spike"
readonly AUTO_LABEL_TYPE_REFACTOR="type:refactor"
readonly AUTO_LABEL_TYPE_DOCS="type:docs"

# Size.
readonly AUTO_LABEL_SIZE_S="size:S"
readonly AUTO_LABEL_SIZE_M="size:M"
readonly AUTO_LABEL_SIZE_L="size:L"
readonly AUTO_LABEL_SIZE_XL="size:XL"

# Convenience groups (space-separated; for installers/validators). Keep in sync above.
readonly AUTO_LABELS_CONTROL="${AUTO_LABEL_ELIGIBLE} ${AUTO_LABEL_CLAIMED} ${AUTO_LABEL_HOLD} ${AUTO_LABEL_STOP} ${AUTO_LABEL_SEEDED}"
readonly AUTO_LABELS_STATUS="${AUTO_LABEL_STATUS_TRIAGE} ${AUTO_LABEL_STATUS_READY} ${AUTO_LABEL_STATUS_IN_PROGRESS} ${AUTO_LABEL_STATUS_IN_REVIEW} ${AUTO_LABEL_STATUS_DONE} ${AUTO_LABEL_STATUS_BLOCKED}"
readonly AUTO_LABELS_PRIORITY="${AUTO_LABEL_PRIORITY_P0} ${AUTO_LABEL_PRIORITY_P1} ${AUTO_LABEL_PRIORITY_P2} ${AUTO_LABEL_PRIORITY_P3}"
readonly AUTO_LABELS_TYPE="${AUTO_LABEL_TYPE_FEATURE} ${AUTO_LABEL_TYPE_BUG} ${AUTO_LABEL_TYPE_CHORE} ${AUTO_LABEL_TYPE_SPIKE} ${AUTO_LABEL_TYPE_REFACTOR} ${AUTO_LABEL_TYPE_DOCS}"
readonly AUTO_LABELS_SIZE="${AUTO_LABEL_SIZE_S} ${AUTO_LABEL_SIZE_M} ${AUTO_LABEL_SIZE_L} ${AUTO_LABEL_SIZE_XL}"
readonly AUTO_LABELS_ALL="${AUTO_LABELS_CONTROL} ${AUTO_LABELS_STATUS} ${AUTO_LABELS_PRIORITY} ${AUTO_LABELS_TYPE} ${AUTO_LABELS_SIZE}"

# --------------------------------------------------------------------------- #
# 10. Exit codes (decisions.md §6 — pin EXACTLY)
# --------------------------------------------------------------------------- #
readonly EX_OK=0                  # success.
readonly EX_ERR=1                 # generic error.
readonly EX_CHECK_FAIL=2          # check / parity FAIL.

# 10-19 claim / concurrency.
readonly EX_CLAIM_LOST=11         # lost the claim race (someone else holds a live lease).
readonly EX_NOT_CLAIMABLE=12      # issue not in a claimable state.
readonly EX_CONCURRENCY=13        # global concurrency ceiling reached.

# 60-69 preflight aborts (one per assertion; emit "ABORT <code> <reason>").
# Each assertion has a UNIQUE code in this band. Mapping (assertion -> code):
readonly EX_PREFLIGHT_ORIGIN=60       # A1 : no GitHub origin remote.
readonly EX_PREFLIGHT_AUTH=61         # A2 : gh not authed / missing scopes.
readonly EX_PREFLIGHT_BRANCHES=62     # A3 : develop and/or develop-auto missing on origin.
readonly EX_PREFLIGHT_YAML=63         # A4 : no YAML parse capability.
readonly EX_PREFLIGHT_PARITY=64       # A5 : CI parity FAIL.
readonly EX_PREFLIGHT_REVIEW=65       # A6 : develop-auto requires reviews, no second approver.
readonly EX_PREFLIGHT_GREENFLOOR=66   # A7'/A7: empty (or disabled) required-check set on develop-auto.
readonly EX_PREFLIGHT_SQUASH=67       # A9 : squash merge disabled on repo.
readonly EX_PREFLIGHT_GITLEAKS=68     # A10: gitleaks not installed.
readonly EX_PREFLIGHT_ACCOUNT=69      # A11: account selection ambiguous / wrong active gh account.
readonly EX_PREFLIGHT_KILLSWITCH=2    # A12: kill-switch already engaged at start.
                                      #      Intentionally maps to EX_CHECK_FAIL (2): a pre-set kill
                                      #      switch is an expected, non-error refusal-to-start, not a
                                      #      preflight misconfiguration. The driver treats 2 here as
                                      #      "clean stop", not "halt for human". (decisions.md A12.)

# 70-79 PR / merge.
readonly EX_PR_BASE_LOCK=70           # base-lock violation (requested base != develop-auto).
readonly EX_PR_PUSH=71                # push fail / branch-origin violation.
readonly EX_PR_VERIFY=72              # post-create base-verify fail (PR base drifted).
readonly EX_PR_NOT_GREEN=73           # required checks not green / PR not open.
readonly EX_PR_GREEN_FLOOR=74         # green-floor: required-check set empty -> refuse merge.
readonly EX_PR_CONFLICT=75            # merge conflict could not be resolved (no force).

# --------------------------------------------------------------------------- #
# 11. Gate / terminal sentinels (decisions.md §6)
#     auto-gate.sh prints exactly "CONTINUE" or "STOP <reason>" on stdout.
# --------------------------------------------------------------------------- #
readonly AUTO_GATE_CONTINUE="CONTINUE"
readonly AUTO_GATE_STOP="STOP"               # followed by a reason token.
# Canonical STOP reason tokens.
readonly AUTO_STOP_REASON_KILL="kill-switch"
readonly AUTO_STOP_REASON_TIME="time"
readonly AUTO_STOP_REASON_MAXPRS="max-prs"
readonly AUTO_STOP_REASON_BACKLOG="backlog-empty"
readonly AUTO_STOP_REASON_OPERATOR="operator"
readonly AUTO_STOP_REASON_ESCALATIONS="max-escalations"

# --------------------------------------------------------------------------- #
# 12. .auto/ disposable cache paths (decisions.md §4 — GitHub is durable state;
#     .auto/ is gitignored and reconstructable cold from GitHub)
# --------------------------------------------------------------------------- #
# AUTO_ROOT defaults to the repo root if discoverable, else cwd. Callers may export
# AUTO_ROOT before sourcing to pin it (e.g. inside a worktree).
: "${AUTO_ROOT:=$( { git rev-parse --show-toplevel 2>/dev/null; } || pwd )}"
export AUTO_ROOT

readonly AUTO_CACHE_DIR="${AUTO_ROOT}/.auto"
readonly AUTO_STATE_DIR="${AUTO_CACHE_DIR}/state"          # run-<id>.json (disposable cache).
readonly AUTO_WORKTREES_DIR="${AUTO_CACHE_DIR}/worktrees"  # per-issue git worktrees.
readonly AUTO_LOG_DIR="${AUTO_CACHE_DIR}/log"              # NDJSON journal (disposable).
readonly AUTO_KILL_CACHE_FILE="${AUTO_CACHE_DIR}/.killcache"   # kill-switch result cache.
readonly AUTO_STOPFLAG_FILE="${AUTO_CACHE_DIR}/.stopflag"      # local operator-stop sentinel.
readonly AUTO_ACCOUNT_CACHE_FILE="${AUTO_CACHE_DIR}/.account"  # gh login resolved at run start (drift guard).

# Per-run state file pattern (run id substituted by the caller).
#   "${AUTO_STATE_DIR}/run-<runId>.json"
readonly AUTO_STATE_FILE_PATTERN="${AUTO_STATE_DIR}/run-%s.json"

# NDJSON log path pattern: one file per UTC day (decisions.md §5).
#   fields: ts, run, lvl, evt, issue, phase, cause
# Resolve today's path with: printf "$AUTO_LOG_PATH_PATTERN" "$(date -u +%Y-%m-%d)"
readonly AUTO_LOG_PATH_PATTERN="${AUTO_LOG_DIR}/%s.ndjson"

# Repo-relative config file (committed to the repo, read at runtime).
readonly AUTO_CONFIG_PATH=".github/auto/auto.config.json"

# --------------------------------------------------------------------------- #
# 13. Verbosity (gates DEBUG logging in log.sh)
# --------------------------------------------------------------------------- #
: "${AUTO_VERBOSE:=0}"   # set to 1 (or pass --verbose) to emit DEBUG lines.
export AUTO_VERBOSE

# --------------------------------------------------------------------------- #
# 14. Tool requirements (the ONLY external binaries the core depends on)
# --------------------------------------------------------------------------- #
readonly AUTO_REQUIRED_TOOLS="git gh jq python3"
readonly AUTO_REQUIRED_TOOLS_COMMIT="gitleaks"   # additionally required before any commit.
