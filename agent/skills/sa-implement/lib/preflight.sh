#!/usr/bin/env bash
# shellcheck shell=bash
#
# preflight.sh — abort-on-fail preflight assertion library for /auto.
#
# Decisions.md D4/D6, architecture §6, spec-ci-parity.md §4.
#
# Defines the assertion functions A1..A12. Each:
#   - performs ONE read-only check (never mutates the repo; NEVER creates branches),
#   - on success prints a single machine-readable line "PASS <id> <detail>" to stdout
#     and returns 0,
#   - on failure prints "ABORT <code> <reason>" to stdout (the EXACT unmet condition),
#     logs an ERROR with cause, and returns the assertion's UNIQUE exit code from
#     constants.sh (60-69 band; A12 maps to EX_CHECK_FAIL=2 as a clean stop).
#
# This file is SOURCED by bin/auto-preflight.sh, which runs A1..A12 in order and
# TERMINATES with the first failing assertion's code. The functions are also
# individually callable by the /loop + cron 双保险 routines, which parse the
# PASS/ABORT lines.
#
# HARD RULE (D4): preflight NEVER auto-creates develop-auto. A3 only reports.
#
# Depends ONLY on: git, gh, jq, python3, gitleaks (presence). Sources constants.sh,
# log.sh, and invokes bin/ci-parity-check.sh for A5.
#
set -euo pipefail

_PF_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=constants.sh
source "${_PF_HERE}/constants.sh"
# shellcheck source=log.sh
source "${_PF_HERE}/log.sh"

if [[ -n "${AUTO_PREFLIGHT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly AUTO_PREFLIGHT_SOURCED=1

# bin/ dir (sibling of lib/), for ci-parity-check.sh.
_PF_BIN="$(cd "${_PF_HERE}/../bin" && pwd)"
readonly _PF_CI_PARITY="${_PF_BIN}/ci-parity-check.sh"

# --------------------------------------------------------------------------- #
# Internal emitters. _pf_pass keeps stdout machine-parseable; _pf_abort prints the
# canonical ABORT line, logs the cause, and returns the unique exit code.
# --------------------------------------------------------------------------- #
_pf_pass() {
  # _pf_pass <id> <detail...>
  local id="$1"; shift || true
  printf 'PASS %s %s\n' "${id}" "$*"
  log_info "preflight_pass" "${id} $*"
  return 0
}
_pf_abort() {
  # _pf_abort <id> <code> <reason...>
  local id="$1" code="$2"; shift 2 || true
  printf 'ABORT %s %s\n' "${code}" "$*"
  log_error "preflight_abort" "${id}" "exit=${code} $*"
  return "${code}"
}

# Resolve owner/repo once, lazily, and cache it. Empty if not a GitHub repo.
_pf_owner_repo() {
  if [[ -z "${_PF_OWNER_REPO:-}" ]]; then
    _PF_OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  printf '%s' "${_PF_OWNER_REPO}"
}

# --------------------------------------------------------------------------- #
# A1 — origin remote exists and is GitHub.
# --------------------------------------------------------------------------- #
preflight_a1_origin() {
  export AUTO_PHASE="preflight"
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "${url}" ]]; then
    _pf_abort "A1" "${EX_PREFLIGHT_ORIGIN}" \
      "no 'origin' remote configured. Add a GitHub origin remote and re-run." || return $?
  fi
  if [[ "${url}" != *"github.com"* ]]; then
    _pf_abort "A1" "${EX_PREFLIGHT_ORIGIN}" \
      "origin remote '${url}' is not a github.com URL. /auto requires a GitHub origin." || return $?
  fi
  _pf_pass "A1" "github origin (${url})"
}

# --------------------------------------------------------------------------- #
# A2 — gh authenticated; token scopes include 'repo' and 'workflow'.
# --------------------------------------------------------------------------- #
preflight_a2_auth() {
  export AUTO_PHASE="preflight"
  if ! gh auth status >/dev/null 2>&1; then
    _pf_abort "A2" "${EX_PREFLIGHT_AUTH}" \
      "gh is not authenticated. Run: gh auth login" || return $?
  fi
  # gh auth status emits scopes on stderr; capture both streams.
  local status_out scopes
  status_out="$(gh auth status 2>&1 || true)"
  scopes="$(printf '%s\n' "${status_out}" | grep -iE 'token scopes|scopes:' | head -n1 || true)"
  if ! printf '%s' "${scopes}" | grep -q "'repo'" && \
     ! printf '%s' "${scopes}" | grep -qw "repo"; then
    _pf_abort "A2" "${EX_PREFLIGHT_AUTH}" \
      "gh token missing 'repo' scope. Run: gh auth refresh -s repo,workflow" || return $?
  fi
  if ! printf '%s' "${scopes}" | grep -q "'workflow'" && \
     ! printf '%s' "${scopes}" | grep -qw "workflow"; then
    _pf_abort "A2" "${EX_PREFLIGHT_AUTH}" \
      "gh token missing 'workflow' scope. Run: gh auth refresh -s repo,workflow" || return $?
  fi
  _pf_pass "A2" "gh authed with repo+workflow scopes"
}

# --------------------------------------------------------------------------- #
# A3 — BOTH develop and develop-auto exist ON ORIGIN. NEVER create develop-auto.
# --------------------------------------------------------------------------- #
preflight_a3_branches() {
  export AUTO_PHASE="preflight"
  local has_dev has_auto
  has_dev="$(git ls-remote --heads origin "${PARITY_REF_BRANCH}" 2>/dev/null || true)"
  has_auto="$(git ls-remote --heads origin "${AUTO_BASE_BRANCH}" 2>/dev/null || true)"
  if [[ -z "${has_dev}" ]]; then
    _pf_abort "A3" "${EX_PREFLIGHT_BRANCHES}" \
      "missing branch on origin: '${PARITY_REF_BRANCH}'. Create it and re-run." || return $?
  fi
  if [[ -z "${has_auto}" ]]; then
    _pf_abort "A3" "${EX_PREFLIGHT_BRANCHES}" \
      "missing branch on origin: '${AUTO_BASE_BRANCH}'. ${AUTO_BASE_BRANCH} is NOT auto-created; create it from ${PARITY_REF_BRANCH} (git branch ${AUTO_BASE_BRANCH} origin/${PARITY_REF_BRANCH} && git push origin ${AUTO_BASE_BRANCH}) and re-run." || return $?
  fi
  _pf_pass "A3" "${PARITY_REF_BRANCH} and ${AUTO_BASE_BRANCH} exist on origin"
}

# --------------------------------------------------------------------------- #
# A4 — YAML parse capability present (yq OR PyYAML OR vendored miniyaml.py).
# We probe the same fallback chain parse_wf.py uses, so an A4 PASS guarantees
# Layer A of parity (A5) can parse workflows.
# --------------------------------------------------------------------------- #
preflight_a4_yaml() {
  export AUTO_PHASE="preflight"
  local lib_dir miniyaml
  lib_dir="${_PF_HERE}"
  miniyaml="${lib_dir}/miniyaml.py"
  if command -v yq >/dev/null 2>&1; then
    _pf_pass "A4" "yaml parse via yq"
    return 0
  fi
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    _pf_pass "A4" "yaml parse via python3 PyYAML"
    return 0
  fi
  if [[ -f "${miniyaml}" ]] && python3 -c "import importlib.util,sys; sys.exit(0 if importlib.util.spec_from_file_location('m','${miniyaml}') else 1)" >/dev/null 2>&1; then
    _pf_pass "A4" "yaml parse via vendored miniyaml.py"
    return 0
  fi
  _pf_abort "A4" "${EX_PREFLIGHT_YAML}" \
    "no YAML parser available (need yq, OR python3 PyYAML [pip install pyyaml], OR vendored lib/miniyaml.py). Cannot verify CI parity." || return $?
}

# --------------------------------------------------------------------------- #
# A5 — CI PARITY: run ci-parity-check.sh; abort with the failing item on non-zero.
# --------------------------------------------------------------------------- #
preflight_a5_parity() {
  export AUTO_PHASE="preflight"
  if [[ ! -x "${_PF_CI_PARITY}" && ! -f "${_PF_CI_PARITY}" ]]; then
    _pf_abort "A5" "${EX_PREFLIGHT_PARITY}" \
      "ci-parity-check.sh not found at ${_PF_CI_PARITY}." || return $?
  fi
  local out rc
  set +e
  out="$(bash "${_PF_CI_PARITY}" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    # Surface the failing item type(s) + exact diverging element(s) from the parity
    # report. Collapse to a single line for the machine-readable ABORT.
    local items
    items="$(printf '%s\n' "${out}" | grep -E '^(FAIL|WARN) ' | tr '\n' '|' | sed 's/|$//')"
    [[ -z "${items}" ]] && items="ci-parity-check exited ${rc}"
    _pf_abort "A5" "${EX_PREFLIGHT_PARITY}" \
      "CI parity FAILED: ${items}" || return $?
  fi
  _pf_pass "A5" "CI parity: develop-auto matches develop"
}

# --------------------------------------------------------------------------- #
# A6 — branch-protection review-count compatibility on develop-auto.
# If develop-auto requires >=1 approving review AND no second-approver credential
# (AUTO_APPROVER_TOKEN) is configured, auto-merge can never self-approve -> ABORT.
# --------------------------------------------------------------------------- #
# Internal: echo the required_approving_review_count for a branch (max of classic
# protection + any ruleset pull_request rule). 0 when none.
_pf_review_count() {
  local branch="$1" owner_repo classic rules max
  owner_repo="$(_pf_owner_repo)"
  classic="$(gh api "repos/${owner_repo}/branches/${branch}/protection" 2>/dev/null \
    | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo 0)"
  rules="$(gh api "repos/${owner_repo}/rules/branches/${branch}" 2>/dev/null \
    | jq -r '[.[]? | select(.type=="pull_request")
             | .parameters.required_approving_review_count // 0] | max // 0' 2>/dev/null || echo 0)"
  [[ "${classic}" =~ ^[0-9]+$ ]] || classic=0
  [[ "${rules}" =~ ^[0-9]+$ ]] || rules=0
  max="${classic}"; [[ "${rules}" -gt "${max}" ]] && max="${rules}"
  printf '%s' "${max}"
}

preflight_a6_review() {
  export AUTO_PHASE="preflight"
  local r
  r="$(_pf_review_count "${AUTO_BASE_BRANCH}")"
  if [[ "${r}" -ge 1 ]]; then
    if [[ -z "${AUTO_APPROVER_TOKEN:-}" ]]; then
      _pf_abort "A6" "${EX_PREFLIGHT_REVIEW}" \
        "${AUTO_BASE_BRANCH} requires ${r} approving review(s); auto-merge cannot self-approve. Set the review count to 0 on ${AUTO_BASE_BRANCH} (decisions.md D6) OR configure AUTO_APPROVER_TOKEN for a distinct approver account." || return $?
    fi
    _pf_pass "A6" "${AUTO_BASE_BRANCH} requires ${r} review(s); AUTO_APPROVER_TOKEN configured"
    return 0
  fi
  _pf_pass "A6" "${AUTO_BASE_BRANCH} requires zero approving reviews"
}

# --------------------------------------------------------------------------- #
# A7 — GREEN FLOOR: develop-auto's required-status-check set must be NON-EMPTY
# (else auto-merge would ship unverified code). Also asserts that if develop has
# checks, develop-auto does too (parity Layer B already enforces equality at A5,
# but A7 is the explicit floor that must hold even when A5's diff happens to pass
# on a misconfigured-but-symmetric empty set). Decisions.md D3 / A7'.
# --------------------------------------------------------------------------- #
preflight_a7_greenfloor() {
  export AUTO_PHASE="preflight"
  local owner_repo req_auto req_dev count_auto count_dev
  owner_repo="$(_pf_owner_repo)"

  req_auto="$( {
      gh api "repos/${owner_repo}/branches/${AUTO_BASE_BRANCH}/protection" 2>/dev/null \
        | jq -r '.required_status_checks.checks[]?.context // empty' 2>/dev/null || true
      gh api "repos/${owner_repo}/rules/branches/${AUTO_BASE_BRANCH}" 2>/dev/null \
        | jq -r '.[]? | select(.type=="required_status_checks")
                 | .parameters.required_status_checks[]?.context // empty' 2>/dev/null || true
    } | LC_ALL=C sort -u )"
  req_dev="$( {
      gh api "repos/${owner_repo}/branches/${PARITY_REF_BRANCH}/protection" 2>/dev/null \
        | jq -r '.required_status_checks.checks[]?.context // empty' 2>/dev/null || true
      gh api "repos/${owner_repo}/rules/branches/${PARITY_REF_BRANCH}" 2>/dev/null \
        | jq -r '.[]? | select(.type=="required_status_checks")
                 | .parameters.required_status_checks[]?.context // empty' 2>/dev/null || true
    } | LC_ALL=C sort -u )"

  count_auto="$(printf '%s' "${req_auto}" | grep -c . || true)"
  count_dev="$(printf '%s' "${req_dev}" | grep -c . || true)"

  if [[ "${AUTO_GREEN_FLOOR}" -eq 1 && "${count_auto}" -eq 0 ]]; then
    _pf_abort "A7" "${EX_PREFLIGHT_GREENFLOOR}" \
      "GREEN FLOOR: ${AUTO_BASE_BRANCH} has NO required status checks; auto-merge would ship unverified code. Establish at least one required status check on ${AUTO_BASE_BRANCH} (matching ${PARITY_REF_BRANCH}; ${count_dev} on ${PARITY_REF_BRANCH})." || return $?
  fi
  if [[ "${count_dev}" -gt 0 && "${count_auto}" -eq 0 ]]; then
    _pf_abort "A7" "${EX_PREFLIGHT_GREENFLOOR}" \
      "${AUTO_BASE_BRANCH} has no required status checks while ${PARITY_REF_BRANCH} has ${count_dev}; the CI gate would be bypassed." || return $?
  fi
  _pf_pass "A7" "${AUTO_BASE_BRANCH} has ${count_auto} required status check(s) (green floor satisfied)"
}

# --------------------------------------------------------------------------- #
# A8 — squash merge enabled on the repo (we merge with --squash). (Was A9 in the
# spec; renumbered to keep A1..A12 contiguous. Maps to EX_PREFLIGHT_SQUASH.)
# Also surfaces the admin-bypass WARN (never abort) from architecture A8.
# --------------------------------------------------------------------------- #
preflight_a8_squash() {
  export AUTO_PHASE="preflight"
  local owner_repo allow_squash
  owner_repo="$(_pf_owner_repo)"
  allow_squash="$(gh api "repos/${owner_repo}" 2>/dev/null | jq -r '.allow_squash_merge // empty' 2>/dev/null || true)"
  if [[ "${allow_squash}" != "true" ]]; then
    _pf_abort "A8" "${EX_PREFLIGHT_SQUASH}" \
      "squash merge is disabled on ${owner_repo} (allow_squash_merge=${allow_squash:-unknown}); /auto merges with --squash (AUTO_MERGE_METHOD=${AUTO_MERGE_METHOD}). Enable squash merging on the repo." || return $?
  fi
  # Admin-bypass advisory (never abort): record that --admin must never be used.
  local viewer_admin
  viewer_admin="$(gh api "repos/${owner_repo}" 2>/dev/null | jq -r '.permissions.admin // false' 2>/dev/null || echo false)"
  if [[ "${viewer_admin}" == "true" ]]; then
    log_info "preflight_admin_warn" "account has admin on ${owner_repo}; auto-merge must NEVER pass --admin (checks would be bypassed)"
  fi
  _pf_pass "A8" "squash merge enabled on ${owner_repo}"
}

# --------------------------------------------------------------------------- #
# A9 — gitleaks installed (commit-gate would otherwise silently skip secret scans).
# (Was A10 in the spec; renumbered. Maps to EX_PREFLIGHT_GITLEAKS.)
# --------------------------------------------------------------------------- #
preflight_a9_gitleaks() {
  export AUTO_PHASE="preflight"
  if ! command -v gitleaks >/dev/null 2>&1; then
    _pf_abort "A9" "${EX_PREFLIGHT_GITLEAKS}" \
      "gitleaks not installed; the commit gate would skip secret scanning. Install it (brew install gitleaks) and re-run." || return $?
  fi
  local ver
  ver="$(gitleaks version 2>/dev/null | head -n1 || echo unknown)"
  _pf_pass "A9" "gitleaks present (${ver})"
}

# --------------------------------------------------------------------------- #
# A10 — account determinism: resolve the ACTIVE local gh login and snapshot it
# for the run. (Maps to EX_PREFLIGHT_ACCOUNT.) The engine follows the installing
# user's local gh account — it NEVER runs `gh auth switch`. If the operator
# exported AUTO_GH_ACCOUNT as a pin, the active login must match it (the switch
# is the human's action). The resolved login is written to .auto/.account so
# mid-run `gh auth switch` flips are caught at every mutation boundary. If a
# second-approver flow is configured, the approver account must differ from the
# author account (best-effort note).
# --------------------------------------------------------------------------- #
preflight_a10_account() {
  export AUTO_PHASE="preflight"
  # Resolve the active login. `gh api user` can be transiently flaky under rapid
  # successive invocations, so retry a few times before declaring failure.
  local active="" _try
  for _try in 1 2 3; do
    active="$(gh api user -q .login 2>/dev/null || true)"
    [[ -n "${active}" ]] && break
    sleep 1
  done
  if [[ -z "${active}" ]]; then
    _pf_abort "A10" "${EX_PREFLIGHT_ACCOUNT}" \
      "could not determine the active gh account (gh api user failed). Run: gh auth login" || return $?
  fi
  # Optional operator pin: assert, never switch.
  if [[ -n "${AUTO_GH_ACCOUNT:-}" && "${active}" != "${AUTO_GH_ACCOUNT}" ]]; then
    _pf_abort "A10" "${EX_PREFLIGHT_ACCOUNT}" \
      "active gh account is '${active}' but AUTO_GH_ACCOUNT pins '${AUTO_GH_ACCOUNT}'. Either unset AUTO_GH_ACCOUNT (to follow the local login) or run: gh auth switch --user ${AUTO_GH_ACCOUNT} — the engine never switches accounts itself." || return $?
  fi
  # Snapshot the run identity for the mid-run drift guard (refresh every run so
  # an intentional between-run account change never false-positives).
  if [[ -n "${AUTO_ACCOUNT_CACHE_FILE:-}" ]]; then
    mkdir -p "$(dirname "${AUTO_ACCOUNT_CACHE_FILE}")" 2>/dev/null || true
    printf '%s\n' "${active}" >"${AUTO_ACCOUNT_CACHE_FILE}" 2>/dev/null || true
  fi
  AUTO_GH_ACCOUNT="${active}"
  export AUTO_GH_ACCOUNT
  # Second-approver disjointness (only relevant when reviews are required on auto).
  if [[ -n "${AUTO_APPROVER_TOKEN:-}" ]]; then
    local approver
    approver="$(GH_TOKEN="${AUTO_APPROVER_TOKEN}" gh api user -q .login 2>/dev/null || true)"
    if [[ -n "${approver}" && "${approver}" == "${active}" ]]; then
      _pf_abort "A10" "${EX_PREFLIGHT_ACCOUNT}" \
        "AUTO_APPROVER_TOKEN resolves to '${approver}', the SAME account as the author '${active}'; a PR author cannot self-approve. Use a distinct approver account." || return $?
    fi
  fi
  _pf_pass "A10" "active gh account = ${active} (resolved from the local gh login)"
}

# --------------------------------------------------------------------------- #
# A11 — a usable git author identity is RESOLVABLE for commits. Resolution
# order (first hit wins, per field): env override (AUTO_GIT_USER_NAME/EMAIL) >
# the user's own git config (local then global) > a GitHub noreply identity
# derived from the active gh login ("<id>+<login>@users.noreply.github.com").
# Read-only: this assertion does NOT mutate config — gh_select_account performs
# the (missing-only) write at mutation time. Aborts only when NO source can
# produce an identity.
# --------------------------------------------------------------------------- #
preflight_a11_identity() {
  export AUTO_PHASE="preflight"
  local name email src="git config"
  name="${AUTO_GIT_USER_NAME:-$(git config user.name 2>/dev/null || true)}"
  email="${AUTO_GIT_USER_EMAIL:-$(git config user.email 2>/dev/null || true)}"
  if [[ -n "${AUTO_GIT_USER_NAME:-}" || -n "${AUTO_GIT_USER_EMAIL:-}" ]]; then
    src="env override + git config"
  fi
  if [[ -z "${name}" || -z "${email}" ]]; then
    local login uid
    login="$(gh api user -q .login 2>/dev/null || true)"
    uid="$(gh api user -q .id 2>/dev/null || true)"
    if [[ -z "${login}" || -z "${uid}" ]]; then
      _pf_abort "A11" "${EX_PREFLIGHT_ACCOUNT}" \
        "no git author identity resolvable: git config user.name/user.email are unset and the GitHub noreply fallback failed (gh api user). Set your identity (git config --global user.name/user.email) or authenticate gh." || return $?
    fi
    [[ -z "${name}"  ]] && name="${login}"
    [[ -z "${email}" ]] && email="${uid}+${login}@users.noreply.github.com"
    src="github noreply fallback"
  fi
  if [[ "${email}" != *"@"* ]]; then
    _pf_abort "A11" "${EX_PREFLIGHT_ACCOUNT}" \
      "resolved git author email '${email}' is not a valid email." || return $?
  fi
  _pf_pass "A11" "git identity resolvable (${name} <${email}>; source: ${src})"
}

# --------------------------------------------------------------------------- #
# A12 — kill-switch clear at start. Killed if EITHER the auto:stop label is present
# on the pinned #auto-control issue OR .auto/STOP exists on develop-auto. A pre-set
# kill switch is an expected refusal-to-start (clean stop), so it maps to
# EX_CHECK_FAIL=2 (NOT a preflight misconfiguration). decisions.md §4 / architecture A12.
#
# Args: optional $1 = control issue number (if preflight already located it); when
# omitted, A12 locates it by the AUTO_CONTROL_MARKER. A missing control issue means
# the kill switch cannot be set yet -> clear.
# --------------------------------------------------------------------------- #
preflight_a12_killswitch() {
  export AUTO_PHASE="preflight"
  local owner_repo ctrl="${1:-}"
  owner_repo="$(_pf_owner_repo)"

  # Locate the control issue by marker if not supplied.
  if [[ -z "${ctrl}" ]]; then
    ctrl="$(gh issue list --repo "${owner_repo}" --state open --search "${AUTO_CONTROL_MARKER} in:body" \
            --json number,body --limit 30 2>/dev/null \
            | jq -r --arg m "${AUTO_CONTROL_MARKER}" '.[] | select(.body|contains($m)) | .number' 2>/dev/null \
            | head -n1 || true)"
  fi

  # PRIMARY: auto:stop label on the control issue.
  if [[ -n "${ctrl}" ]]; then
    local labels
    labels="$(gh issue view "${ctrl}" --repo "${owner_repo}" --json labels \
              -q '[.labels[].name]|join(" ")' 2>/dev/null || true)"
    if printf '%s' "${labels}" | grep -qw "${AUTO_LABEL_STOP}"; then
      _pf_abort "A12" "${EX_PREFLIGHT_KILLSWITCH}" \
        "kill-switch is ENGAGED: label '${AUTO_LABEL_STOP}' is set on #auto-control (#${ctrl}). A human set it; remove the label to start." || return $?
    fi
  fi

  # FALLBACK: .auto/STOP present on develop-auto (read remotely so local ignore is
  # irrelevant). 404 (absent) is the normal, clear case.
  if gh api "repos/${owner_repo}/contents/${AUTO_STOP_FILE_PATH}?ref=${AUTO_BASE_BRANCH}" \
       >/dev/null 2>&1; then
    _pf_abort "A12" "${EX_PREFLIGHT_KILLSWITCH}" \
      "kill-switch is ENGAGED: file '${AUTO_STOP_FILE_PATH}' exists on ${AUTO_BASE_BRANCH}. Delete it to start." || return $?
  fi

  _pf_pass "A12" "kill-switch clear (no ${AUTO_LABEL_STOP} on #auto-control, no ${AUTO_STOP_FILE_PATH} on ${AUTO_BASE_BRANCH})"
}

# --------------------------------------------------------------------------- #
# Convenience driver: run A1..A12 in order, stop at the first failure, return its
# code. bin/auto-preflight.sh may call this OR invoke the assertions individually
# (e.g. to interleave label/control-issue setup). The control issue number can be
# passed so A12 does not re-query.
#   preflight_run_all [control-issue-number]
# --------------------------------------------------------------------------- #
preflight_run_all() {
  local ctrl="${1:-}"
  preflight_a1_origin     || return $?
  preflight_a2_auth       || return $?
  preflight_a3_branches   || return $?
  preflight_a4_yaml       || return $?
  preflight_a5_parity     || return $?
  preflight_a6_review     || return $?
  preflight_a7_greenfloor || return $?
  preflight_a8_squash     || return $?
  preflight_a9_gitleaks   || return $?
  preflight_a10_account   || return $?
  preflight_a11_identity  || return $?
  preflight_a12_killswitch "${ctrl}" || return $?
  return 0
}
