#!/usr/bin/env bash
# shellcheck shell=bash
#
# install-labels.sh — idempotently install/sync the /auto label taxonomy.
#
# This is a TEMPLATE that ships into a target repo at `.github/auto/install-labels.sh`
# alongside `.github/auto/labels.json`. It is intentionally SELF-CONTAINED — it does
# NOT source the /auto lib (constants.sh etc.) because once installed it lives in an
# arbitrary repo with no access to that tree. It depends only on `gh` + `jq` + bash.
#
# It reads every label from `labels.json` (the single source of truth, which mirrors
# lib/constants.sh §9 / decisions.md §3) and, for each, runs:
#       gh label create <name> --color <c> --description <d>   (first time)
#   ||  gh label edit   <name> --color <c> --description <d>   (already exists)
# so re-running it is safe and converges colors/descriptions to labels.json. It is
# ADDITIVE: it never deletes labels the repo already has (a human may have extras).
#
# Usage:
#   bash install-labels.sh [--repo <owner/repo>] [--file <labels.json>] [--quiet]
#
#   --repo <owner/repo>   target repo (default: the repo `gh` resolves from cwd).
#   --file <path>         labels JSON (default: labels.json next to this script).
#   --quiet               suppress per-label progress lines (errors still print).
#
# Exit codes:
#   0   all labels created/edited successfully (idempotent).
#   1   argument / dependency error, or one or more labels could not be synced.
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# --------------------------------------------------------------------------- #
# Minimal standalone logging (this template has no log.sh to source).
# --------------------------------------------------------------------------- #
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log_info()  { [[ "${QUIET:-0}" -eq 1 ]] || printf '%s [INFO ] %s\n' "$(_ts)" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n' "$(_ts)" "$*" >&2; }

# --------------------------------------------------------------------------- #
# Args.
# --------------------------------------------------------------------------- #
REPO=""
LABELS_FILE="${_SELF_DIR}/labels.json"
QUIET=0

print_help() {
  sed -n '3,/^[^#]/{ /^[^#]/d; s/^#\{1,2\} \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --file)  LABELS_FILE="${2:?--file requires a path}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) print_help ;;
    *)
      log_error "unknown argument: $1"
      exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Dependency + input checks.
# --------------------------------------------------------------------------- #
for tool in gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "required tool '${tool}' not found on PATH"
    exit 1
  fi
done

if [[ ! -f "$LABELS_FILE" ]]; then
  log_error "labels file not found: ${LABELS_FILE}"
  exit 1
fi

if ! jq -e 'type == "array"' "$LABELS_FILE" >/dev/null 2>&1; then
  log_error "labels file is not a JSON array: ${LABELS_FILE}"
  exit 1
fi

# Thread --repo to every gh call when given; otherwise gh resolves from cwd.
GH_REPO_ARGS=()
[[ -n "$REPO" ]] && GH_REPO_ARGS=(--repo "$REPO")

log_info "installing /auto labels from ${LABELS_FILE}${REPO:+ into ${REPO}}"

# --------------------------------------------------------------------------- #
# Iterate labels. Read name/color/description into a single TSV stream so names
# or descriptions with spaces survive the loop (jq -r with tab separators).
# --------------------------------------------------------------------------- #
created=0
edited=0
failed=0
total=0

# Use a NUL-safe-ish TSV: name<TAB>color<TAB>description, one per line. Newlines in
# descriptions are not expected in the taxonomy; @tsv would escape them if present.
while IFS=$'\t' read -r name color desc; do
  [[ -z "$name" ]] && continue
  total=$(( total + 1 ))

  # Try create first (idempotent strategy): if the label is new, this succeeds; if
  # it already exists, gh exits non-zero ("already exists") and we fall through to
  # edit so colors/descriptions converge to labels.json.
  if gh label create "$name" "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" \
        --color "$color" --description "$desc" >/dev/null 2>&1; then
    created=$(( created + 1 ))
    log_info "created label: ${name}"
  elif gh label edit "$name" "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" \
        --color "$color" --description "$desc" >/dev/null 2>&1; then
    edited=$(( edited + 1 ))
    log_info "synced label:  ${name}"
  else
    failed=$(( failed + 1 ))
    log_error "could not create or edit label: ${name}"
  fi
done < <(jq -r '.[] | [.name, (.color // "ededed"), (.description // "")] | @tsv' "$LABELS_FILE")

log_info "label sync complete: ${created} created, ${edited} synced, ${failed} failed (of ${total})"

if (( failed > 0 )); then
  log_error "${failed} label(s) failed to sync"
  exit 1
fi
exit 0
