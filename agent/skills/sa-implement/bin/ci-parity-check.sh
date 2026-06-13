#!/usr/bin/env bash
# shellcheck shell=bash
#
# ci-parity-check.sh — verify CI parity between develop-auto and develop.
#
# Decisions.md D2 / architecture §2.2 / spec-ci-parity.md §2.
#
# PARITY DEFINITION (formal): the set of REQUIRED status checks GitHub will demand
# before a PR -> develop-auto can merge MUST equal the set it demands for a PR ->
# develop, considering BOTH the workflows/jobs that trigger AND the branch-protection
# /ruleset required-check contexts. PASS only if both sets match exactly.
#
# THREE LAYERS, all must PASS:
#   Layer A  Triggered-check-name parity (simulate Actions branch filtering).
#            - read each workflow AS IT EXISTS on each branch (WORKFLOW_FILE_DIVERGENCE)
#            - parse YAML via lib/parse_wf.py (yq/PyYAML/miniyaml fallback chain)
#            - simulate on.pull_request.branches/-ignore via lib/branch_match.py
#              (BRANCH_FILTER_DIVERGENCE)
#            - resolve check-run NAMES incl. matrix expansion + reusable-uses ref
#              (REUSABLE_REF_DIVERGENCE, CHECK_NAME_SET_DIVERGENCE)
#   Layer B  Required-status-check parity (classic branch protection UNION rulesets)
#            (REQUIRED_CHECK_DIVERGENCE)
#   Layer C  Cross-consistency: REQUIRED(develop-auto) subset of NAMES(develop-auto)
#            (ORPHAN_REQUIRED_CHECK; external apps -> EXTERNAL_REQUIRED_CHECK WARN)
#
# Exclusion list: auto-base-guard.yml and any workflow whose line 1 carries the
# marker `# auto:exclude-from-parity` are dropped from BOTH branch sets (asserted
# symmetric across branches).
#
# OUTPUT: deterministic. On PASS prints "PASS ci-parity" to stdout, exit 0.
#         On FAIL prints each failing item type + the exact diverging element(s)
#         to stderr, prints "FAIL ci-parity" to stdout, exit 2 (EX_CHECK_FAIL).
#
# Depends ONLY on: git, gh, jq, python3 (+ optional yq accelerator inside parse_wf.py).
#
set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="$(cd "${_HERE}/../lib" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_LIB}/constants.sh"
# shellcheck source=../lib/log.sh
source "${_LIB}/log.sh"

AUTO_PHASE="${AUTO_PHASE:-parity}"

# Helper scripts (owned by the YAML-parsing agent; canonical paths per decisions.md §7).
PARSE_WF="${_LIB}/parse_wf.py"
BRANCH_MATCH="${_LIB}/branch_match.py"

# Scratch workspace (disposable; under .auto cache so it is gitignored).
_WORK="$(mktemp -d "${TMPDIR:-/tmp}/auto-parity.XXXXXX")"
cleanup() { rm -rf "${_WORK}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Accumulators for failing item types -> printed to stderr at the end.
declare -a FAIL_ITEMS=()
declare -a WARN_ITEMS=()

_fail() {
  # _fail <ITEM_TYPE> <detail...>
  local item="$1"; shift || true
  FAIL_ITEMS+=("${item}: $*")
  log_error "parity_item" "${item}" "$*"
}
_warn() {
  local item="$1"; shift || true
  WARN_ITEMS+=("${item}: $*")
  log_info "parity_warn" "${item} $*"
}

# --------------------------------------------------------------------------- #
# Resolve owner/repo once. Refuse to run if not a GitHub repo (caller/preflight
# A1 should have caught this, but be defensive).
# --------------------------------------------------------------------------- #
OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
if [[ -z "${OWNER_REPO}" ]]; then
  log_error "parity_no_repo" "gh-repo-view-failed" "cannot resolve owner/repo from gh"
  echo "FAIL ci-parity"
  exit "${EX_CHECK_FAIL}"
fi

# Assert the helper parsers exist; without them Layer A cannot run deterministically.
for _h in "${PARSE_WF}" "${BRANCH_MATCH}"; do
  if [[ ! -f "${_h}" ]]; then
    log_error "parity_missing_helper" "missing:${_h}" "required YAML helper not found"
    echo "FAIL ci-parity"
    exit "${EX_CHECK_FAIL}"
  fi
done

# Ensure refs are present locally for git-show reads (best effort; non-fatal if the
# fetch fails — git show against origin/<branch> will surface the real error).
git fetch --quiet origin "${PARITY_REF_BRANCH}" "${AUTO_BASE_BRANCH}" 2>/dev/null || \
  log_debug "parity_fetch_skip" "could not pre-fetch refs; relying on existing origin refs"

# --------------------------------------------------------------------------- #
# Per-branch helpers.
# --------------------------------------------------------------------------- #

# list_workflow_paths <branch> -> stdout: one workflow path per line (sorted).
# Reads the tree AS IT EXISTS ON THE BRANCH.
list_workflow_paths() {
  local branch="$1"
  git ls-tree -r "origin/${branch}" --name-only 2>/dev/null \
    | grep -E '^\.github/workflows/.*\.(yml|yaml)$' \
    | LC_ALL=C sort || true
}

# is_excluded <branch> <path> -> exit 0 if the workflow is on the exclusion list.
# Excluded if basename == auto-base-guard.yml OR line 1 carries the marker comment.
is_excluded() {
  local branch="$1" path="$2" base first
  base="$(basename "${path}")"
  [[ "${base}" == "auto-base-guard.yml" ]] && return 0
  first="$(git show "origin/${branch}:${path}" 2>/dev/null | head -n1 || true)"
  # Tolerate leading whitespace; match the marker anywhere on line 1 of a comment.
  if printf '%s' "${first}" | grep -qE '^\s*#\s*auto:exclude-from-parity'; then
    return 0
  fi
  return 1
}

# read_workflow <branch> <path> -> writes the file content to stdout.
read_workflow() { git show "origin/$1:$2" 2>/dev/null || true; }

# parse_one <branch> <path> -> writes parsed-workflow JSON to stdout, or fails.
# parse_wf.py contract: reads workflow YAML on stdin, prints a JSON object:
#   { "has_pull_request": bool,
#     "pr_branches": [glob,...]|null,            # on.pull_request.branches
#     "pr_branches_ignore": [glob,...]|null,     # on.pull_request.branches-ignore
#     "jobs": [ { "id","name","check_names":[expanded names...],
#                 "uses": "<ref>"|null }, ... ] }
# (matrix Cartesian expansion + include/exclude already applied into check_names.)
parse_one() {
  local branch="$1" path="$2"
  read_workflow "${branch}" "${path}" | python3 "${PARSE_WF}" 2>/dev/null
}

# branch_triggers <parsed-json-file> <branch-name> -> echoes "true"/"false".
# branch_match.py contract: argv1 = branch name; reads the parsed-workflow JSON on
# stdin; replicates GitHub semantics (no branches/-ignore => match all; branches
# last-match-wins with !neg; branches-ignore => NONE match); prints "true"/"false".
branch_triggers() {
  local parsed_file="$1" branch_name="$2"
  python3 "${BRANCH_MATCH}" "${branch_name}" < "${parsed_file}" 2>/dev/null
}

# --------------------------------------------------------------------------- #
# LAYER A — triggered-check-name parity.
# Produces, in ${_WORK}: names_develop, names_auto  (sorted unique check names that
# are TRIGGERED on the respective branch). Records failing items along the way.
# --------------------------------------------------------------------------- #
: > "${_WORK}/names_develop"
: > "${_WORK}/names_auto"

layer_a() {
  list_workflow_paths "${PARITY_REF_BRANCH}" > "${_WORK}/wf_develop_all"
  list_workflow_paths "${AUTO_BASE_BRANCH}"  > "${_WORK}/wf_auto_all"

  # Build the included (non-excluded) workflow path sets for each branch.
  : > "${_WORK}/wf_develop"
  : > "${_WORK}/wf_auto"
  local p
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    is_excluded "${PARITY_REF_BRANCH}" "${p}" && continue
    printf '%s\n' "${p}" >> "${_WORK}/wf_develop"
  done < "${_WORK}/wf_develop_all"
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    is_excluded "${AUTO_BASE_BRANCH}" "${p}" && continue
    printf '%s\n' "${p}" >> "${_WORK}/wf_auto"
  done < "${_WORK}/wf_auto_all"

  # Assert the EXCLUSION set is symmetric across branches (an exclusion present on
  # one branch but not the other is itself a divergence).
  comm -3 \
    <(comm -23 "${_WORK}/wf_develop_all" "${_WORK}/wf_develop") \
    <(comm -23 "${_WORK}/wf_auto_all"   "${_WORK}/wf_auto") \
    > "${_WORK}/excl_diff" || true
  if [[ -s "${_WORK}/excl_diff" ]]; then
    _fail "EXCLUSION_SET_DIVERGENCE" "$(tr '\n' ' ' < "${_WORK}/excl_diff")"
  fi

  # The union of non-excluded workflow paths across both branches. We evaluate every
  # path; a path missing on one branch is caught by WORKFLOW_FILE_DIVERGENCE.
  LC_ALL=C sort -u "${_WORK}/wf_develop" "${_WORK}/wf_auto" > "${_WORK}/wf_union"

  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue

    local on_dev on_auto
    on_dev=0; on_auto=0
    grep -qxF "${p}" "${_WORK}/wf_develop" && on_dev=1
    grep -qxF "${p}" "${_WORK}/wf_auto"   && on_auto=1

    # WORKFLOW_FILE_DIVERGENCE: present (non-excluded) on one branch only.
    if [[ "${on_dev}" -ne "${on_auto}" ]]; then
      _fail "WORKFLOW_FILE_DIVERGENCE" \
        "${p} present on $([[ ${on_dev} -eq 1 ]] && echo "${PARITY_REF_BRANCH}" || echo "${AUTO_BASE_BRANCH}") only"
      continue
    fi

    # Both branches have it. Compare the raw bytes — a per-branch file difference is
    # itself a parity failure (covers paths/jobs/matrix differing between branches).
    local dev_blob auto_blob
    dev_blob="$(read_workflow "${PARITY_REF_BRANCH}" "${p}")"
    auto_blob="$(read_workflow "${AUTO_BASE_BRANCH}" "${p}")"
    if [[ "${dev_blob}" != "${auto_blob}" ]]; then
      _fail "WORKFLOW_FILE_DIVERGENCE" "${p} content differs between ${PARITY_REF_BRANCH} and ${AUTO_BASE_BRANCH}"
      continue
    fi

    # Parse the workflow on each branch (identical bytes, but parse per branch so a
    # parser/env difference surfaces, and so reusable-uses recursion is per branch).
    local parsed_dev="${_WORK}/parsed.dev.$$" parsed_auto="${_WORK}/parsed.auto.$$"
    if ! parse_one "${PARITY_REF_BRANCH}" "${p}" > "${parsed_dev}" || [[ ! -s "${parsed_dev}" ]]; then
      _fail "WORKFLOW_PARSE_FAILURE" "${p} on ${PARITY_REF_BRANCH}"
      continue
    fi
    if ! parse_one "${AUTO_BASE_BRANCH}" "${p}" > "${parsed_auto}" || [[ ! -s "${parsed_auto}" ]]; then
      _fail "WORKFLOW_PARSE_FAILURE" "${p} on ${AUTO_BASE_BRANCH}"
      continue
    fi

    # Skip workflows that do not even use pull_request as a trigger (no PR checks).
    local has_pr_dev has_pr_auto
    has_pr_dev="$(jq -r '.has_pull_request // false' "${parsed_dev}")"
    has_pr_auto="$(jq -r '.has_pull_request // false' "${parsed_auto}")"
    if [[ "${has_pr_dev}" != "${has_pr_auto}" ]]; then
      _fail "BRANCH_FILTER_DIVERGENCE" "${p} pull_request trigger present on one branch only"
      continue
    fi
    [[ "${has_pr_dev}" == "true" ]] || continue

    # REUSABLE_REF_DIVERGENCE: the uses: refs must be identical between branches.
    # (Bytes already match, so a divergence here is informational, but assert it.)
    local uses_dev uses_auto
    uses_dev="$(jq -r '[.jobs[]?.uses // empty]|sort|join(",")' "${parsed_dev}")"
    uses_auto="$(jq -r '[.jobs[]?.uses // empty]|sort|join(",")' "${parsed_auto}")"
    if [[ "${uses_dev}" != "${uses_auto}" ]]; then
      _fail "REUSABLE_REF_DIVERGENCE" "${p}: develop uses [${uses_dev}] vs develop-auto uses [${uses_auto}]"
      continue
    fi

    # Branch-filter simulation: triggers(develop) must equal triggers(develop-auto).
    local t_dev t_auto
    t_dev="$(branch_triggers "${parsed_dev}" "${PARITY_REF_BRANCH}")"
    t_auto="$(branch_triggers "${parsed_auto}" "${AUTO_BASE_BRANCH}")"
    if [[ "${t_dev}" != "true" && "${t_dev}" != "false" ]] || \
       [[ "${t_auto}" != "true" && "${t_auto}" != "false" ]]; then
      _fail "BRANCH_FILTER_DIVERGENCE" "${p}: branch_match.py returned non-boolean (dev='${t_dev}' auto='${t_auto}')"
      continue
    fi
    if [[ "${t_dev}" != "${t_auto}" ]]; then
      _fail "BRANCH_FILTER_DIVERGENCE" \
        "${p}: triggers(${PARITY_REF_BRANCH})=${t_dev} but triggers(${AUTO_BASE_BRANCH})=${t_auto}"
      continue
    fi

    # Accumulate the TRIGGERED check names per branch.
    if [[ "${t_dev}" == "true" ]]; then
      jq -r '.jobs[]?.check_names[]?' "${parsed_dev}" >> "${_WORK}/names_develop"
    fi
    if [[ "${t_auto}" == "true" ]]; then
      jq -r '.jobs[]?.check_names[]?' "${parsed_auto}" >> "${_WORK}/names_auto"
    fi

    rm -f "${parsed_dev}" "${parsed_auto}" 2>/dev/null || true
  done < "${_WORK}/wf_union"

  # Normalise the name sets and compare.
  LC_ALL=C sort -u "${_WORK}/names_develop" -o "${_WORK}/names_develop"
  LC_ALL=C sort -u "${_WORK}/names_auto"    -o "${_WORK}/names_auto"
  if ! diff -q "${_WORK}/names_develop" "${_WORK}/names_auto" >/dev/null 2>&1; then
    local symdiff
    symdiff="$(comm -3 "${_WORK}/names_develop" "${_WORK}/names_auto" | tr '\t' ' ' | tr '\n' ';' | sed 's/;/; /g')"
    _fail "CHECK_NAME_SET_DIVERGENCE" "${symdiff}"
  fi
}

# --------------------------------------------------------------------------- #
# LAYER B — required-status-check parity (classic protection UNION rulesets).
# Produces, in ${_WORK}: req_develop, req_auto (sorted unique required contexts).
# --------------------------------------------------------------------------- #
: > "${_WORK}/req_develop"
: > "${_WORK}/req_auto"

# required_checks_for <branch> -> stdout sorted-unique required contexts.
required_checks_for() {
  local branch="$1"
  {
    # Classic branch protection (404 if unprotected -> empty).
    gh api "repos/${OWNER_REPO}/branches/${branch}/protection" 2>/dev/null \
      | jq -r '.required_status_checks.checks[]?.context // empty' 2>/dev/null || true
    # Rulesets effective on the branch (aggregates org + repo rulesets).
    gh api "repos/${OWNER_REPO}/rules/branches/${branch}" 2>/dev/null \
      | jq -r '.[]? | select(.type=="required_status_checks")
               | .parameters.required_status_checks[]?.context // empty' 2>/dev/null || true
  } | LC_ALL=C sort -u
}

layer_b() {
  required_checks_for "${PARITY_REF_BRANCH}" > "${_WORK}/req_develop"
  required_checks_for "${AUTO_BASE_BRANCH}"  > "${_WORK}/req_auto"
  if ! diff -q "${_WORK}/req_develop" "${_WORK}/req_auto" >/dev/null 2>&1; then
    local symdiff
    symdiff="$(comm -3 "${_WORK}/req_develop" "${_WORK}/req_auto" | tr '\t' ' ' | tr '\n' ';' | sed 's/;/; /g')"
    _fail "REQUIRED_CHECK_DIVERGENCE" "${symdiff}"
  fi
}

# --------------------------------------------------------------------------- #
# LAYER C — cross-consistency: REQUIRED(develop-auto) subset of NAMES(develop-auto).
# Any required context NOT produced by a triggered Actions check on develop-auto is
# either ORPHAN (fails) or an external-app context present on BOTH branches (WARN).
# --------------------------------------------------------------------------- #
layer_c() {
  # Contexts required on develop-auto but not in the triggered Actions name set.
  comm -23 "${_WORK}/req_auto" "${_WORK}/names_auto" > "${_WORK}/orphan_auto" || true
  local ctx
  while IFS= read -r ctx; do
    [[ -z "${ctx}" ]] && continue
    # External-app allowance: present (and identically required) on BOTH branches.
    if grep -qxF "${ctx}" "${_WORK}/req_develop"; then
      _warn "EXTERNAL_REQUIRED_CHECK" "${ctx} (not produced by an Actions workflow; assumed external app, present on both branches)"
    else
      _fail "ORPHAN_REQUIRED_CHECK" "${ctx} required on ${AUTO_BASE_BRANCH} but never produced by a triggered check"
    fi
  done < "${_WORK}/orphan_auto"
}

# --------------------------------------------------------------------------- #
# Run all layers (always run all three so the report lists every diverging item).
# --------------------------------------------------------------------------- #
log_info "parity_start" "owner=${OWNER_REPO} ${PARITY_REF_BRANCH} vs ${AUTO_BASE_BRANCH}"
layer_a
layer_b
layer_c

if [[ ${#WARN_ITEMS[@]} -gt 0 ]]; then
  for w in "${WARN_ITEMS[@]}"; do
    printf 'WARN  %s\n' "${w}" >&2
  done
fi

if [[ ${#FAIL_ITEMS[@]} -gt 0 ]]; then
  for f in "${FAIL_ITEMS[@]}"; do
    printf 'FAIL  %s\n' "${f}" >&2
  done
  log_error "parity_fail" "${#FAIL_ITEMS[@]}-items" "CI parity FAILED"
  echo "FAIL ci-parity"
  exit "${EX_CHECK_FAIL}"
fi

log_info "parity_pass" "develop-auto CI is byte-equivalent to develop"
echo "PASS ci-parity"
exit "${EX_OK}"
