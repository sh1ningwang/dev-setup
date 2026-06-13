#!/usr/bin/env bash
# shellcheck shell=bash
#
# auto-preflight.sh — the /auto preflight orchestrator (architecture §6, D4).
#
# Runs the full preflight sequence before ANY autonomous work:
#   1. account determinism FIRST (A10) so every subsequent gh call uses the pinned
#      account, then the read-only prereq assertions A1..A11,
#   2. side-effects that require a green prereq set: install the label taxonomy
#      (idempotent) and locate-or-create the pinned #auto-control issue + the
#      transient per-run status issue,
#   3. A12 kill-switch check (using the located control issue).
#
# Role workers are native in-session Claude subagents spawned by the /auto
# orchestrator (the live session) — there is NO external adapter to probe.
#
# ABORTS with the EXACT unmet condition (the assertion's "ABORT <code> <reason>"
# line) and exits with that assertion's unique code. NEVER creates develop-auto.
#
# Usage:
#   auto-preflight.sh [--run-id <id>] [--no-status-issue]
#
# Stdout (machine-parseable): the PASS/ABORT lines from each assertion, plus two
# result lines on success:
#   CONTROL_ISSUE <number>
#   STATUS_ISSUE  <number|->        (- when --no-status-issue)
# Exit: 0 on full PASS; otherwise the failing assertion's exit code.
#
# Depends ONLY on: git, gh, jq, python3, gitleaks. Sources constants/log/preflight.
#
set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="$(cd "${_HERE}/../lib" && pwd)"
# shellcheck source=../lib/constants.sh
source "${_LIB}/constants.sh"
# shellcheck source=../lib/log.sh
source "${_LIB}/log.sh"
# shellcheck source=../lib/preflight.sh
source "${_LIB}/preflight.sh"

export AUTO_PHASE="preflight"

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
RUN_ID=""
MAKE_STATUS_ISSUE=1

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)          RUN_ID="${2:-}"; shift 2 ;;
    --no-status-issue) MAKE_STATUS_ISSUE=0; shift ;;
    -h|--help)         print_help ;;
    *) log_error "preflight_bad_arg" "$1" "unknown argument"; exit "${EX_ERR}" ;;
  esac
done

if [[ -z "${RUN_ID}" ]]; then
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
export AUTO_RUN_ID="${RUN_ID}"

log_info "preflight_begin" "run=${RUN_ID}"

# Abort wrapper: run an assertion, and on non-zero exit IMMEDIATELY terminate with
# that code (the assertion already printed its ABORT line + logged the cause).
_assert() {
  local fn="$1"; shift || true
  set +e
  "${fn}" "$@"
  local rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    log_error "preflight_terminated" "${fn}" "exit=${rc}"
    exit "${rc}"
  fi
}

# --------------------------------------------------------------------------- #
# Phase 1 — assertions. Account determinism (A10) runs FIRST so all later gh calls
# (including label install + control issue) use the resolved run account. A2 (auth) is a
# precondition of A10, so run A1/A2 first, then A10, then the remainder.
# --------------------------------------------------------------------------- #
_assert preflight_a1_origin
_assert preflight_a2_auth
_assert preflight_a10_account     # resolve the ACTIVE local gh login BEFORE any further gh use.
_assert preflight_a3_branches
_assert preflight_a4_yaml
_assert preflight_a5_parity
_assert preflight_a6_review
_assert preflight_a7_greenfloor
_assert preflight_a8_squash
_assert preflight_a9_gitleaks
_assert preflight_a11_identity

OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
if [[ -z "${OWNER_REPO}" ]]; then
  log_error "preflight_no_repo" "gh-repo-view-failed" "cannot resolve owner/repo"
  exit "${EX_PREFLIGHT_ORIGIN}"
fi

# --------------------------------------------------------------------------- #
# Phase 2 — write side-effects.
#   (a) install/refresh the label taxonomy (idempotent), via install-labels.sh.
#   (b) locate-or-create the pinned #auto-control issue.
#   (c) create the transient per-run status issue (unless suppressed).
# --------------------------------------------------------------------------- #
INSTALL_LABELS="$(cd "${_HERE}/../templates/.github/auto" 2>/dev/null && pwd)/install-labels.sh"
LABELS_JSON="$(cd "${_HERE}/../templates/.github/auto" 2>/dev/null && pwd)/labels.json"

install_labels() {
  # install-labels.sh contract: idempotently creates/updates every label in
  # labels.json on $OWNER_REPO via `gh label create/edit`. Accepts the repo via
  # `--repo` or the GH_REPO env; here we pass --repo explicitly. Exit 0 on success.
  if [[ -f "${INSTALL_LABELS}" ]]; then
    if bash "${INSTALL_LABELS}" --repo "${OWNER_REPO}" >/dev/null 2>&1; then
      log_info "preflight_labels" "installed via install-labels.sh"
      return 0
    fi
    log_error "preflight_labels_fail" "install-labels.sh" "non-zero; falling back to inline install"
  fi
  # Fallback inline installer (idempotent) if install-labels.sh is unavailable.
  if [[ ! -f "${LABELS_JSON}" ]]; then
    log_error "preflight_labels_fail" "no-labels-json" "labels.json missing at ${LABELS_JSON}"
    return 1
  fi
  local count
  count="$(jq 'length' "${LABELS_JSON}")"
  local i name color desc
  for ((i=0; i<count; i++)); do
    name="$(jq -r ".[$i].name" "${LABELS_JSON}")"
    color="$(jq -r ".[$i].color" "${LABELS_JSON}")"
    desc="$(jq -r ".[$i].description // \"\"" "${LABELS_JSON}")"
    gh label create "${name}" --repo "${OWNER_REPO}" --color "${color}" --description "${desc}" 2>/dev/null \
      || gh label edit "${name}" --repo "${OWNER_REPO}" --color "${color}" --description "${desc}" >/dev/null 2>&1 \
      || log_debug "preflight_label_skip" "could not create/edit label ${name}"
  done
  log_info "preflight_labels" "installed inline (${count} labels)"
}

# locate_control_issue -> echoes the control issue number, or empty if none.
locate_control_issue() {
  gh issue list --repo "${OWNER_REPO}" --state open --search "${AUTO_CONTROL_MARKER} in:body" \
      --json number,body --limit 30 2>/dev/null \
    | jq -r --arg m "${AUTO_CONTROL_MARKER}" \
        '.[] | select(.body|contains($m)) | .number' 2>/dev/null \
    | head -n1 || true
}

create_control_issue() {
  local body url num
  body="$(cat <<EOF
${AUTO_CONTROL_MARKER}

# auto-control

This is the permanent, repo-global control issue for the \`/auto\` autonomous agent.

**Kill-switch:** add the label \`${AUTO_LABEL_STOP}\` to THIS issue to halt all \`/auto\`
runs (a fresh run also refuses to start while it is set). Remove the label to resume.
Fallback signal: commit an empty file at \`${AUTO_STOP_FILE_PATH}\` on the
\`${AUTO_BASE_BRANCH}\` branch.

Do not close or unpin this issue.
EOF
)"
  url="$(gh issue create --repo "${OWNER_REPO}" --title "${AUTO_CONTROL_TITLE}" --body "${body}" 2>/dev/null || true)"
  [[ -z "${url}" ]] && return 1
  num="$(basename "${url}")"
  # Best-effort pin (non-fatal if pinning is unavailable / over the pin cap).
  gh issue pin "${num}" --repo "${OWNER_REPO}" >/dev/null 2>&1 \
    || log_debug "preflight_pin_skip" "could not pin #${num}"
  printf '%s' "${num}"
}

create_status_issue() {
  local body url num
  body="$(cat <<EOF
${AUTO_STATUS_MARKER} run=${RUN_ID}

# auto status — run ${RUN_ID}

Transient per-run dashboard. Updated each iteration; unpinned on terminal state.
Started: $(date -u +%Y-%m-%dT%H:%M:%SZ).
EOF
)"
  url="$(gh issue create --repo "${OWNER_REPO}" --title "auto-status ${RUN_ID}" --body "${body}" 2>/dev/null || true)"
  [[ -z "${url}" ]] && return 1
  num="$(basename "${url}")"
  printf '%s' "${num}"
}

CONTROL_ISSUE=""
STATUS_ISSUE="-"

install_labels || { log_error "preflight_labels_fatal" "install" "label install failed"; exit "${EX_ERR}"; }

CONTROL_ISSUE="$(locate_control_issue)"
if [[ -z "${CONTROL_ISSUE}" ]]; then
  CONTROL_ISSUE="$(create_control_issue)" || {
    log_error "preflight_control_fail" "create" "could not create #auto-control"; exit "${EX_ERR}"; }
  log_info "preflight_control" "created #auto-control #${CONTROL_ISSUE}"
else
  log_info "preflight_control" "located #auto-control #${CONTROL_ISSUE}"
fi

if [[ "${MAKE_STATUS_ISSUE}" -eq 1 ]]; then
  STATUS_ISSUE="$(create_status_issue)" || {
    log_error "preflight_status_fail" "create" "could not create per-run status issue"
    STATUS_ISSUE="-"; }
  [[ "${STATUS_ISSUE}" != "-" ]] && log_info "preflight_status" "created status issue #${STATUS_ISSUE}"
fi

# --------------------------------------------------------------------------- #
# Phase 3 — A12 kill-switch (with the located control issue, so it does not re-query).
# --------------------------------------------------------------------------- #
_assert preflight_a12_killswitch "${CONTROL_ISSUE}"

# --------------------------------------------------------------------------- #
# (Native plugin: role workers are in-session Claude subagents spawned by the /auto
# orchestrator via the Agent tool. There is no external adapter to probe, so the old
# capability self-test is gone — the live session IS the host.)
# --------------------------------------------------------------------------- #

# --------------------------------------------------------------------------- #
# Success summary.
# --------------------------------------------------------------------------- #
printf 'CONTROL_ISSUE %s\n' "${CONTROL_ISSUE:--}"
printf 'STATUS_ISSUE %s\n' "${STATUS_ISSUE}"
log_info "preflight_ok" "all assertions PASS; control=#${CONTROL_ISSUE:--} status=#${STATUS_ISSUE}"
exit "${EX_OK}"
