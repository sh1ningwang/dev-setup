#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-seed.sh — the --seed / triage pass (architecture §8; spec-conventions §6).
#
# THIN ORCHESTRATOR: arg parse -> scan -> classify -> dedup -> file. The signal
# scanners, the candidate model, and the fingerprint/dedup engine live in the
# sourced helper library lib/seed.sh (seed_scan_todos / seed_scan_tests /
# seed_scan_docs / seed_scan_deps / seed_scan_context; seed_fingerprint;
# seed_load_fingerprints / seed_dedup_decision). This file owns ONLY the pipeline
# wiring, the optional classify-and-size refinement, label/body assembly, the
# decision table, and the gh issue-filing phase.
#
#   SIGNAL SCANNERS (lib/seed.sh; git + gh + jq + python3 + standard CLI only)
#     1. TODO/FIXME/HACK/XXX            via `git grep` (line-number-independent key).
#     2. failing / skipped tests        via the project's fast test command (best-effort).
#     3. README / doc gaps              missing README or required sections.
#     4. dependency drift / advisories  npm/pip/go outdated + audit (best-effort, non-fatal).
#     5. --context brain-dump           one candidate per operator bullet/intent.
#
#   CLASSIFY + SIZE
#     Each candidate carries deterministic suggested {type,priority,size} from the
#     per-scanner heuristics in lib/seed.sh — sufficient to file correct issues. This
#     pass is FULLY DETERMINISTIC and never spawns Claude (session-spine: only the
#     /auto session spawns subagents). Optional AI enrichment of filed issues is the
#     /auto orchestrator's job (SKILL.md §3), not this script's.
#
#   FILE ISSUES (Issue-Form-shaped bodies; labels computed from the taxonomy)
#     `gh issue create` with the matching type:* label + computed priority:* + size:*
#     + auto:seeded. Fully-specced items also get status:ready + auto:eligible; every
#     other item (brain-dump, under-specced signal) stays status:triage and is NOT
#     auto-pickable until a human promotes it (decisions.md §3; spec-conventions §6.3).
#     A --theme/--label value is added to every seeded issue.
#
#   DEDUP (idempotent re-seed)
#     Every seeded body ends with a hidden, LOCATION-STABLE fingerprint marker
#       <!-- auto-seed-fp: <sha1> -->
#     sha1 = sha1( kind ":" canonical_key ), canonical_key NEVER includes line numbers
#     or versions (TODO: relpath+symbol+normalized-text; test: suite::name; doc:
#     relpath+section; dep: ecosystem+package; brain-dump: normalized bullet text).
#     Before filing, the existing open+closed auto:seeded fingerprints are read once:
#       - fp on an OPEN issue   -> skip (already tracked).
#       - fp on a CLOSED issue  -> skip, UNLESS --reseed-closed (then refile).
#       - fp absent             -> create.
#
#   --dry-run prints the create/skip DECISION TABLE and performs NO gh writes at all
#     (no issue create, no label writes); issue# shows "-". Read-only gh queries (the
#     fingerprint pre-read) are still allowed so the rehearsal is faithful.
#
# All gh writes run as the installing user's ACTIVE local gh account (resolved at
# runtime, never via `gh auth switch`); identity drift is HARD-REFUSED. The core
# uses git + gh ONLY (never the GitHub MCP).
#
# Usage:
#   auto-seed.sh [--context <text|@file>] [--theme <label> | --label <label>]
#                [--reseed-closed] [--dry-run] [--no-tests] [--no-deps] [--verbose]
#
#   --context <text|@file>  operator brain-dump: free text, or @path to a file of
#                           bullet intents (one intent per non-empty line / `- ` bullet).
#   --theme/--label <lbl>   scope/extra label added to every seeded issue (the label
#                           must already exist in the repo; install-labels.sh + your own).
#   --reseed-closed         refile fingerprints whose only match is a CLOSED issue.
#   --dry-run               print the decision table; mutate nothing on GitHub.
#   --no-tests              skip the failing/skipped-test scanner (it can be slow).
#   --no-deps               skip the dependency-drift scanner.
#   --verbose               emit DEBUG logging (AUTO_VERBOSE=1).
#
# Exit codes (decisions.md §6):
#   0   pass completed (issues filed and/or skipped; or dry-run table printed).
#   1   generic / argument error.
#   69  gh account could not be resolved, or drifted from the run identity (non-dry-run).
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Source shared libs (lib/ is a sibling of bin/). lib/seed.sh transitively pulls
# in constants.sh + log.sh + gh.sh (defensive, idempotent guards), so sourcing it
# alone is sufficient — but we source the foundational libs explicitly too so the
# orchestrator's intent is obvious and order-independent.
# --------------------------------------------------------------------------- #
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_SELF_DIR}/../lib/constants.sh"
# shellcheck source=../lib/log.sh
source "${_SELF_DIR}/../lib/log.sh"
# shellcheck source=../lib/gh.sh
source "${_SELF_DIR}/../lib/gh.sh"
# shellcheck source=../lib/seed.sh
source "${_SELF_DIR}/../lib/seed.sh"

export AUTO_PHASE="${AUTO_PHASE:-seed}"

# Print the leading header comment block (top-of-file usage) and exit 0.
print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

# --------------------------------------------------------------------------- #
# Args. These set the module-level config globals lib/seed.sh reads:
#   CONTEXT_RAW, THEME_LABEL, RESEED_CLOSED, DRY_RUN, SCAN_TESTS, SCAN_DEPS.
# --------------------------------------------------------------------------- #
# shellcheck disable=SC2034  # consumed by sourced lib/seed.sh (cross-file globals).
CONTEXT_RAW=""
THEME_LABEL=""
RESEED_CLOSED=0
DRY_RUN=0
SCAN_TESTS=1
SCAN_DEPS=1

# SCAN_TESTS / SCAN_DEPS are flipped to 0 below and then read by lib/seed.sh.
# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)        CONTEXT_RAW="${2:?--context requires a value}"; shift 2 ;;
    --theme|--label)  THEME_LABEL="${2:?$1 requires a label}"; shift 2 ;;
    --reseed-closed)  RESEED_CLOSED=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --no-tests)       SCAN_TESTS=0; shift ;;
    --no-deps)        SCAN_DEPS=0; shift ;;
    --verbose)        AUTO_VERBOSE=1; export AUTO_VERBOSE; shift ;;
    -h|--help)        print_help ;;
    *) log_error "seed_args" "unknown-arg" "unknown argument: $1"; exit "$EX_ERR" ;;
  esac
done

# Resolve repo root for scanning (the seed scanners run against the working tree).
SCAN_ROOT="${AUTO_ROOT}"
[[ -d "$SCAN_ROOT" ]] || SCAN_ROOT="$(pwd)"

log_info "seed_start" "root=${SCAN_ROOT} dry_run=${DRY_RUN} reseed_closed=${RESEED_CLOSED} theme=${THEME_LABEL:-none}"

# Tools the scanners want beyond the core four (all optional; degrade gracefully).
command -v git  >/dev/null || { log_error "seed_deps" "git-missing" "git is required"; exit "$EX_ERR"; }
command -v jq   >/dev/null || { log_error "seed_deps" "jq-missing" "jq is required"; exit "$EX_ERR"; }

# Candidate accumulator (appended to by the lib/seed.sh scanners; see that file's
# header for the candidate object shape and the candidate model contract).
CANDIDATES="[]"

# =========================================================================== #
# CLASSIFY + SIZE (deterministic; no in-shell subagent).
#
# Each candidate already carries deterministic suggested {type,priority,size,title,
# acceptance} from the per-scanner heuristics in lib/seed.sh — sufficient to file
# correct issues. Session-spine: this shell NEVER spawns Claude. If richer AI
# refinement is wanted, the /auto orchestrator (the live session) enriches specific filed
# issues afterward with a read-only subagent (SKILL.md §3) — the seed script itself stays
# runnable cold with git+gh only and never spawns Claude.
# =========================================================================== #
classify_and_size() {
  local n; n="$(printf '%s' "$CANDIDATES" | jq 'length')"
  (( n > 0 )) || return 0
  log_info "seed_classify" "deterministic suggestions for ${n} candidate(s) (no in-shell subagent)"
  return 0
}

# =========================================================================== #
# Label mapping + form-shaped body assembly.
# =========================================================================== #

# _type_label <suggested_type> -> canonical type:* label (validated; fallback chore).
_type_label() {
  case "$1" in
    feature)  printf '%s' "$AUTO_LABEL_TYPE_FEATURE" ;;
    bug)      printf '%s' "$AUTO_LABEL_TYPE_BUG" ;;
    chore)    printf '%s' "$AUTO_LABEL_TYPE_CHORE" ;;
    spike)    printf '%s' "$AUTO_LABEL_TYPE_SPIKE" ;;
    refactor) printf '%s' "$AUTO_LABEL_TYPE_REFACTOR" ;;
    docs)     printf '%s' "$AUTO_LABEL_TYPE_DOCS" ;;
    *)        printf '%s' "$AUTO_LABEL_TYPE_CHORE" ;;
  esac
}

# _priority_label <Pn> -> canonical priority:* label (validated; fallback P2).
_priority_label() {
  case "$1" in
    P0) printf '%s' "$AUTO_LABEL_PRIORITY_P0" ;;
    P1) printf '%s' "$AUTO_LABEL_PRIORITY_P1" ;;
    P2) printf '%s' "$AUTO_LABEL_PRIORITY_P2" ;;
    P3) printf '%s' "$AUTO_LABEL_PRIORITY_P3" ;;
    *)  printf '%s' "$AUTO_LABEL_PRIORITY_P2" ;;
  esac
}

# _size_label <S|M|L|XL> -> canonical size:* label (validated; fallback default L).
_size_label() {
  case "$1" in
    S)  printf '%s' "$AUTO_LABEL_SIZE_S" ;;
    M)  printf '%s' "$AUTO_LABEL_SIZE_M" ;;
    L)  printf '%s' "$AUTO_LABEL_SIZE_L" ;;
    XL) printf '%s' "$AUTO_LABEL_SIZE_XL" ;;
    *)  case "$AUTO_SIZE_DEFAULT" in
          S) printf '%s' "$AUTO_LABEL_SIZE_S" ;;
          M) printf '%s' "$AUTO_LABEL_SIZE_M" ;;
          XL) printf '%s' "$AUTO_LABEL_SIZE_XL" ;;
          *) printf '%s' "$AUTO_LABEL_SIZE_L" ;;
        esac ;;
  esac
}

# _title_prefix <suggested_type> -> the conventional title prefix the Issue Forms use.
_title_prefix() {
  case "$1" in
    feature)  printf 'feat' ;;
    bug)      printf 'fix' ;;
    docs)     printf 'docs' ;;
    refactor) printf 'refactor' ;;
    spike)    printf 'spike' ;;
    *)        printf 'chore' ;;
  esac
}

# _is_fully_specced <kind> -> 0 (true) if the candidate is specced enough to be
#   auto:eligible immediately. Brain-dump items and the README-missing gap are NOT
#   (they need human scoping); concrete code/test/dep signals ARE (acceptance is
#   self-contained). This realizes decisions.md §3 / spec-conventions §6.3.
_is_fully_specced() {
  case "$1" in
    brain-dump) return 1 ;;
    *)          return 0 ;;
  esac
}

# _build_body <context> <acceptance> <constraints> <kind> <fingerprint>
#   Assemble an Issue-Form-shaped Markdown body ending with the fingerprint marker.
#   Mirrors the field set of templates/.github/ISSUE_TEMPLATE/*.yml so a human sees
#   the same structure whether an issue was filed by the form or by --seed.
_build_body() {
  local context="$1" acceptance="$2" constraints="$3" kind="$4" fp="$5"
  printf '### Context / Problem\n\n%s\n\n' "$context"
  printf '### Acceptance Criteria\n\n%s\n\n' "$acceptance"
  if [[ -n "$constraints" ]]; then
    printf '### Constraints / Non-goals\n\n%s\n\n' "$constraints"
  fi
  printf '### Definition of Done\n\n'
  printf -- '- [ ] Acceptance criteria met\n'
  printf -- '- [ ] Tests added/updated; full suite green\n'
  printf -- '- [ ] Docs updated if behavior/API changed\n'
  printf -- '- [ ] gitleaks clean; conventional, atomic, buildable-per-commit\n'
  printf -- '- [ ] No `Co-Authored-By` lines in any commit\n'
  printf -- '- [ ] PR targets `%s`; CI 100%% green\n\n' "$AUTO_BASE_BRANCH"
  printf -- '---\n'
  # Footnote distinguishes auto-pickable items from triage items needing human scope.
  local note
  if _is_fully_specced "$kind"; then
    note="Promoted to \`${AUTO_LABEL_STATUS_READY}\` + \`${AUTO_LABEL_ELIGIBLE}\`; /auto may pick it up."
  else
    note="Left at \`${AUTO_LABEL_STATUS_TRIAGE}\`; a human must confirm scope before it becomes \`${AUTO_LABEL_ELIGIBLE}\`."
  fi
  printf '_Filed automatically by `/auto --seed`. %s_\n\n' "$note"
  # The hidden, location-stable dedup fingerprint marker (state-model §5.2).
  printf '%s %s -->\n' "$AUTO_SEED_FP_PREFIX" "$fp"
}

# =========================================================================== #
# Fingerprint pre-read state. The dedup engine (seed_load_fingerprints /
# seed_dedup_decision / seed_fp_issue_number) lives in lib/seed.sh and reads/writes
# this map; the orchestrator just owns the variable.
# =========================================================================== #
# shellcheck disable=SC2034  # read/written by sourced lib/seed.sh dedup engine.
FP_MAP_JSON="{}"

# =========================================================================== #
# Decision table.
# =========================================================================== #
TABLE_ROWS=()  # each row: kind|title|type|priority|size|decision|issue#

_table_add() { TABLE_ROWS+=("$1"); }

print_table() {
  printf '\n'
  printf '%-12s | %-44s | %-9s | %-3s | %-4s | %-14s | %s\n' \
    "KIND" "TITLE" "TYPE" "PRI" "SIZE" "DECISION" "ISSUE#"
  printf '%s\n' "-------------+----------------------------------------------+-----------+-----+------+----------------+--------"
  local row
  for row in "${TABLE_ROWS[@]}"; do
    IFS='|' read -r kind title type prio size decision issue <<<"$row"
    printf '%-12s | %-44.44s | %-9s | %-3s | %-4s | %-14s | %s\n' \
      "$kind" "$title" "$type" "$prio" "$size" "$decision" "${issue:--}"
  done
  printf '\n'
}

# =========================================================================== #
# RUN: scan -> classify -> dedup -> (file | dry-run table).
# =========================================================================== #

# 1. Scan all signals + the brain-dump (lib/seed.sh; append to $CANDIDATES).
seed_scan_todos
seed_scan_tests
seed_scan_docs
seed_scan_deps
seed_scan_context

N_CANDIDATES="$(printf '%s' "$CANDIDATES" | jq 'length')"
log_info "seed_scanned" "candidates=${N_CANDIDATES}"

if (( N_CANDIDATES == 0 )); then
  log_info "seed_done" "no candidates found; nothing to seed"
  print_table
  exit "$EX_OK"
fi

# 2. Classify + size (subagent refinement; deterministic fallback).
classify_and_size

# 3. Load existing fingerprints for dedup (read-only; lib/seed.sh).
seed_load_fingerprints

# 4. Account resolution — ONLY needed for real writes. Under --dry-run we never mutate,
#    so account resolution still runs read-only (a dry-run rehearsal asserts the
#    same identity guard but performs no writes).
if (( ! DRY_RUN )); then
  gh_select_account >/dev/null || exit "$EX_PREFLIGHT_ACCOUNT"
fi

# 5. Iterate candidates: decide, then file (or table-only under dry-run).
CREATED=0 SKIPPED=0
COUNT="$N_CANDIDATES"
for (( idx=0; idx<COUNT; idx++ )); do
  C="$(printf '%s' "$CANDIDATES" | jq -c ".[$idx]")"
  kind="$(printf '%s' "$C" | jq -r '.kind')"
  title="$(printf '%s' "$C" | jq -r '.title')"
  context="$(printf '%s' "$C" | jq -r '.context')"
  acceptance="$(printf '%s' "$C" | jq -r '.acceptance')"
  constraints="$(printf '%s' "$C" | jq -r '.constraints')"
  key="$(printf '%s' "$C" | jq -r '.canonical_key')"
  stype="$(printf '%s' "$C" | jq -r '.suggested_type')"
  sprio="$(printf '%s' "$C" | jq -r '.suggested_priority')"
  ssize="$(printf '%s' "$C" | jq -r '.suggested_size')"

  fp="$(seed_fingerprint "$kind" "$key")"
  decision="$(seed_dedup_decision "$fp")"

  type_label="$(_type_label "$stype")"
  prio_label="$(_priority_label "$sprio")"
  size_label="$(_size_label "$ssize")"
  prefix="$(_title_prefix "$stype")"
  full_title="${prefix}: ${title}"

  case "$decision" in
    skip-open|skip-closed)
      local_issue="$(seed_fp_issue_number "$fp")"
      _table_add "${kind}|${title}|${type_label#type:}|${sprio}|${ssize}|${decision}|#${local_issue}"
      SKIPPED=$(( SKIPPED + 1 ))
      log_info "seed_skip" "kind=${kind} fp=${fp:0:12} decision=${decision} issue=#${local_issue}"
      continue
      ;;
    create|reseed-closed) : ;;  # fall through to create.
  esac

  # Compute the label set. Brain-dump / under-specced stay status:triage (NOT
  # auto:eligible). Fully-specced concrete signals are status:ready + auto:eligible.
  labels=("$type_label" "$prio_label" "$size_label" "$AUTO_LABEL_SEEDED")
  if _is_fully_specced "$kind"; then
    labels+=("$AUTO_LABEL_STATUS_READY" "$AUTO_LABEL_ELIGIBLE")
    lifecycle="ready"
  else
    labels+=("$AUTO_LABEL_STATUS_TRIAGE")
    lifecycle="triage"
  fi
  [[ -n "$THEME_LABEL" ]] && labels+=("$THEME_LABEL")

  if (( DRY_RUN )); then
    _table_add "${kind}|${title}|${type_label#type:}|${sprio}|${ssize}|${decision}(${lifecycle})|-"
    CREATED=$(( CREATED + 1 ))
    log_info "seed_dryrun" "would-create kind=${kind} fp=${fp:0:12} labels=[${labels[*]}]"
    continue
  fi

  # --- Real filing path (non-dry-run). ------------------------------------- #
  body="$(_build_body "$context" "$acceptance" "$constraints" "$kind" "$fp")"
  body_file="$(mktemp "${TMPDIR:-/tmp}/auto-seed-body.XXXXXX")"
  printf '%s' "$body" > "$body_file"

  label_args=()
  for l in "${labels[@]}"; do label_args+=(--label "$l"); done

  set +e
  url="$(gh_retry gh.seed_create -- issue create \
          --title "$full_title" --body-file "$body_file" "${label_args[@]}" 2>&1)"
  rc=$?
  set -e
  rm -f "$body_file"

  if (( rc != 0 )); then
    # A common cause is a missing label (e.g. an uninstalled --theme label). Report
    # and continue so one bad candidate does not abort the whole pass.
    log_error "seed_create" "issue-create-failed" \
      "kind=${kind} fp=${fp:0:12} rc=${rc} -- ${url:0:200}"
    _table_add "${kind}|${title}|${type_label#type:}|${sprio}|${ssize}|create-FAILED|-"
    continue
  fi

  issue_num="$(grep -oE '/issues/[0-9]+' <<<"$url" | grep -oE '[0-9]+' | tail -1 || true)"
  CREATED=$(( CREATED + 1 ))
  _table_add "${kind}|${title}|${type_label#type:}|${sprio}|${ssize}|${decision}(${lifecycle})|#${issue_num:-?}"
  log_info "seed_created" "kind=${kind} fp=${fp:0:12} issue=#${issue_num:-?} lifecycle=${lifecycle} url=${url}"
done

# 6. Output the decision table + a one-line summary.
print_table
if (( DRY_RUN )); then
  log_info "seed_done" "DRY-RUN: would create=${CREATED} skip=${SKIPPED} (no GitHub writes performed)"
else
  log_info "seed_done" "created=${CREATED} skipped=${SKIPPED}"
fi
exit "$EX_OK"
