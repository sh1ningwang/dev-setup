#!/usr/bin/env bash
# shellcheck shell=bash
#
# seed.sh — sourced helpers for the --seed / triage pass (architecture §8).
#
# This library holds the INDEPENDENT, individually-testable pieces of the seed
# pass so that bin/auto-seed.sh stays a thin orchestrator (arg parse -> scan ->
# classify -> dedup -> file). Nothing here runs at source time; every unit is a
# function, sharing no state between scanners (each is coverable alone). Pieces:
#   CANDIDATE MODEL  — _push_candidate appends to the $CANDIDATES JSON array.
#   PURE HELPERS     — seed_sha1 / seed_fingerprint / seed_norm / seed_upper /
#                      seed_relpath (deterministic, no GitHub, no side effects).
#   SIGNAL SCANNERS  — seed_scan_{todos,tests,docs,deps,context}: scan the working
#                      tree (git + jq + standard CLI only) and append candidates.
#   DEDUP ENGINE     — seed_load_fingerprints (one read-only gh pre-read) +
#                      seed_dedup_decision / seed_fp_issue_number (pure map lookups).
#
# Module-level state the orchestrator (bin/auto-seed.sh) OWNS and these functions
# read/append:
#   CANDIDATES     JSON array (jq -c) of candidates         [appended by scanners]
#   FP_MAP_JSON    fingerprint -> {number,state} map         [set by seed_load_fingerprints]
#   SCAN_ROOT      repo root the scanners run against         [read]
#   CONTEXT_RAW    --context text|@file                       [read by seed_scan_context]
#   SCAN_TESTS / SCAN_DEPS   1/0 — enable that scanner        [read]
#   RESEED_CLOSED  1/0 — refile closed-only fingerprints      [read by seed_dedup_decision]
#
# Candidate object shape is documented at _push_candidate (its arg order is the
# authoritative spec). canonical_key is ALWAYS location-stable — never a line
# number or a version. The fingerprint is seed_fingerprint(kind, canonical_key) =
# sha1(kind ":" key), computed by the orchestrator at file time (state-model §5.2).
#
# The core uses git + gh ONLY (never the GitHub MCP). Sourced, never executed.
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Dependency sourcing (defensive; idempotent guards in each lib). lib/ is this
# file's own directory; constants/log/gh are siblings.
# --------------------------------------------------------------------------- #
if [[ -z "${AUTO_CONSTANTS_SOURCED:-}" ]]; then
  # shellcheck source=constants.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/constants.sh"
fi
if [[ -z "${AUTO_LOG_SOURCED:-}" ]]; then
  # shellcheck source=log.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log.sh"
fi
if [[ -z "${AUTO_GH_SOURCED:-}" ]]; then
  # shellcheck source=gh.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh.sh"
fi

if [[ -n "${AUTO_SEED_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly AUTO_SEED_SOURCED=1

# =========================================================================== #
# Candidate model.
# =========================================================================== #

# _push_candidate <kind> <title> <context> <acceptance> <constraints> <files-json> \
#                 <canonical_key> <s_type> <s_priority> <s_size>
#   Append one candidate object to $CANDIDATES. files-json is a JSON array string.
_push_candidate() {
  local kind="$1" title="$2" context="$3" acceptance="$4" constraints="$5" \
        files_json="$6" key="$7" stype="$8" sprio="$9" ssize="${10}"
  CANDIDATES="$(printf '%s' "$CANDIDATES" | jq -c \
    --arg kind "$kind" --arg title "$title" --arg context "$context" \
    --arg acceptance "$acceptance" --arg constraints "$constraints" \
    --argjson files "${files_json:-[]}" --arg key "$key" \
    --arg stype "$stype" --arg sprio "$sprio" --arg ssize "$ssize" '
    . + [ { kind:$kind, title:$title, context:$context, acceptance:$acceptance,
            constraints:$constraints, files:$files, canonical_key:$key,
            suggested_type:$stype, suggested_priority:$sprio, suggested_size:$ssize } ]')"
}

# =========================================================================== #
# Pure helpers (deterministic; no GitHub, no side effects).
# =========================================================================== #

# seed_sha1 <string> -> 40-hex sha1 of the arg. Prefers sha1sum, falls back to
# shasum then python3 (one of which is present on every target host).
seed_sha1() {
  local s="$1"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha1sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum -a 1 | cut -d' ' -f1
  else
    printf '%s' "$s" | python3 -c 'import sys,hashlib; sys.stdout.write(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())'
  fi
}

# seed_fingerprint <kind> <canonical_key> -> sha1(kind ":" key). Location-stable.
seed_fingerprint() { seed_sha1 "${1}:${2}"; }

# seed_norm <text> -> lowercased, whitespace-collapsed, trimmed (stable text keys).
seed_norm() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' \
    | sed -E 's/^ +//; s/ +$//'
}

# seed_upper <text> -> uppercased. Portable (bash 3.2 has no ${var^^} expansion; the
# default macOS /usr/bin/env bash is 3.2, so we never use case-modifying expansions).
seed_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# seed_relpath <abs-or-rel> -> path relative to SCAN_ROOT (best-effort; falls back to input).
seed_relpath() {
  local p="$1"
  case "$p" in
    "${SCAN_ROOT}/"*) printf '%s' "${p#"${SCAN_ROOT}/"}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# =========================================================================== #
# SCANNER 1 — TODO / FIXME / HACK / XXX (git grep; line-number-independent key).
#   Group by file + nearest-symbol-ish anchor + normalized comment text, so the
#   same marker keeps ONE fingerprint even if it moves lines (architecture §8).
#   FIXME/HACK -> type:bug, priority:P2; TODO/XXX -> type:chore, priority:P3.
# =========================================================================== #
seed_scan_todos() {
  log_debug "seed_scan" "todos: git grep TODO|FIXME|HACK|XXX"
  # Only scan tracked files; exclude lockfiles / minified / vendored noise.
  local hits
  hits="$(git -C "$SCAN_ROOT" grep -nEI '(TODO|FIXME|HACK|XXX)' -- \
            ':!*.lock' ':!*.min.*' ':!*.map' ':!*vendor/*' ':!*node_modules/*' \
            2>/dev/null || true)"
  [[ -z "$hits" ]] && { log_debug "seed_scan" "todos: none"; return 0; }

  local line file ln text marker rtype rprio norm key
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # `git grep -n` => path:line:content
    file="${line%%:*}"
    local rest="${line#*:}"
    ln="${rest%%:*}"
    text="${rest#*:}"
    # Identify the strongest marker present (FIXME/HACK are defects).
    if   grep -qE 'FIXME|HACK' <<<"$text"; then marker="fixme"; rtype="bug";   rprio="P2"
    elif grep -qE 'XXX'        <<<"$text"; then marker="todo";  rtype="chore"; rprio="P3"
    else                                        marker="todo";  rtype="chore"; rprio="P3"
    fi
    # Strip leading comment punctuation and the marker word from the visible text.
    local cleaned
    cleaned="$(printf '%s' "$text" \
      | sed -E 's/^[[:space:]]*([#/*-]+|<!--)?[[:space:]]*//; s/(TODO|FIXME|HACK|XXX)[:( ]?//')"
    cleaned="$(seed_norm "$cleaned")"
    [[ -z "$cleaned" ]] && cleaned="(no description)"
    norm="$cleaned"
    # canonical_key: relpath + normalized text (a coarse, line-stable "symbol" proxy).
    # We deliberately exclude the line number so a marker that shifts lines is not refiled.
    key="$(seed_relpath "$file")|${norm}"
    local rel; rel="$(seed_relpath "$file")"
    local umarker; umarker="$(seed_upper "$marker")"
    local title="${umarker}: ${cleaned:0:60} (${file##*/})"
    local ctx="A \`${umarker}\` marker in \`${rel}\` needs resolving.
Original comment (current location line ${ln}):

> ${text}

Decide whether to act on it or remove it; do not leave stale markers."
    local acc="- [ ] Resolve or intentionally remove the \`${umarker}\` at \`${rel}\`
- [ ] No new \`${umarker}\`/\`FIXME\`/\`HACK\` introduced by the change"
    _push_candidate "$marker" "$title" "$ctx" "$acc" "" \
      "$(jq -cn --arg f "$rel" '[$f]')" "$key" "$rtype" "$rprio" "S"
  done <<<"$hits"
}

# =========================================================================== #
# SCANNER 2 — failing / skipped tests (best-effort; SCAN_TESTS=0 skips).
#   Detect skipped tests statically (stable, fast). Running the suite is gated to
#   when a clear, fast command is discoverable; failures -> type:bug/P1.
# =========================================================================== #
seed_scan_tests() {
  (( SCAN_TESTS )) || { log_debug "seed_scan" "tests: skipped (--no-tests)"; return 0; }

  # --- 2a. Statically detected SKIPPED tests (no execution; always safe). ----- #
  log_debug "seed_scan" "tests: static skip detection"
  local skips
  skips="$(git -C "$SCAN_ROOT" grep -nEI \
      '(it|test|describe)\.skip|xit\(|xdescribe\(|@pytest\.mark\.skip|@unittest\.skip|t\.Skip\(|\.Skip\(|#\[ignore\]' \
      -- ':!*.lock' ':!*node_modules/*' ':!*vendor/*' 2>/dev/null || true)"
  if [[ -n "$skips" ]]; then
    local line file ln text key title
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      file="${line%%:*}"; local rest="${line#*:}"; ln="${rest%%:*}"; text="${rest#*:}"
      # canonical_key: relpath + normalized skipped-line text (test-id proxy).
      key="$(seed_relpath "$file")|skip|$(seed_norm "$text")"
      title="re-enable skipped test in ${file##*/}"
      _push_candidate "test-skip" "$title" \
        "A skipped test in \`$(seed_relpath "$file")\` (around line ${ln}) hides coverage:

> ${text}

Re-enable it (fixing the underlying cause) or delete it with justification." \
        "- [ ] Skipped test re-enabled and green, OR removed with a documented reason
- [ ] No unjustified skips remain in this file" \
        "" "$(jq -cn --arg f "$(seed_relpath "$file")" '[$f]')" "$key" "test" "P2" "S"
    done <<<"$skips"
  fi

  # --- 2b. Run the fast test command IF clearly discoverable (best-effort). ---- #
  # We only RUN tests when a single obvious command exists; a heavy/ambiguous suite
  # is left to build-check.sh at commit time. Any non-zero exit -> one bug candidate.
  local test_cmd="" eco=""
  if   [[ -f "${SCAN_ROOT}/package.json" ]] && jq -e '.scripts.test' "${SCAN_ROOT}/package.json" >/dev/null 2>&1; then
    test_cmd="npm test --silent"; eco="node"
  elif [[ -f "${SCAN_ROOT}/go.mod" ]] && command -v go >/dev/null 2>&1; then
    test_cmd="go test ./..."; eco="go"
  fi
  if [[ -n "$test_cmd" ]]; then
    log_info "seed_scan" "tests: running fast suite (${eco}): ${test_cmd}"
    local out rc
    set +e
    out="$( cd "$SCAN_ROOT" && eval "timeout 300 ${test_cmd}" 2>&1 )"
    rc=$?
    set -e
    if (( rc != 0 )); then
      # canonical_key: ecosystem only (so a still-red suite is not refiled each run;
      # the issue tracks "the suite is red", updated by humans, not per-failure churn).
      local key="suite|${eco}"
      _push_candidate "test-fail" "fix failing ${eco} test suite" \
        "The fast ${eco} test command (\`${test_cmd}\`) exits non-zero. Tail of output:

\`\`\`
$(printf '%s\n' "$out" | tail -n 25)
\`\`\`

Restore the suite to green." \
        "- [ ] Root cause of the failing suite identified
- [ ] All previously-failing tests pass
- [ ] No tests disabled merely to go green" \
        "" "[]" "$key" "bug" "P1" "M"
    else
      log_debug "seed_scan" "tests: ${eco} suite green"
    fi
  else
    log_debug "seed_scan" "tests: no clearly-fast suite command; skipping execution"
  fi
}

# =========================================================================== #
# SCANNER 3 — README / doc gaps.
#   Missing README at root, or a README lacking Usage/Install/Getting-Started.
#   type:docs, priority:P3.
# =========================================================================== #
seed_scan_docs() {
  log_debug "seed_scan" "docs: README presence/sections"
  # Does the repo actually contain code worth documenting?
  local has_code=0
  if git -C "$SCAN_ROOT" ls-files -- \
       '*.sh' '*.py' '*.js' '*.ts' '*.go' '*.rs' '*.java' '*.rb' 2>/dev/null \
       | grep -q .; then
    has_code=1
  fi
  (( has_code )) || { log_debug "seed_scan" "docs: no code files; skipping"; return 0; }

  local readme=""
  local cand
  for cand in README.md README README.rst README.txt readme.md; do
    if [[ -f "${SCAN_ROOT}/${cand}" ]]; then readme="${SCAN_ROOT}/${cand}"; break; fi
  done

  if [[ -z "$readme" ]]; then
    _push_candidate "doc-gap" "add a project README" \
      "The repository has source code but no README at its root. New contributors
(and /auto) need a top-level overview, install steps, and usage." \
      "- [ ] README.md created at the repo root
- [ ] Includes Overview, Install, and Usage sections" \
      "" "[]" "README.md|missing" "docs" "P3" "S"
    return 0
  fi

  # README exists — check for the staple sections (case-insensitive heading match).
  local sec missing=()
  for sec in "Install" "Usage" "Getting Started"; do
    if ! grep -qiE "^#{1,6}[[:space:]].*${sec}" "$readme"; then
      missing+=("$sec")
    fi
  done
  # Only file if BOTH Install and Usage flavors are absent (avoid noise on one-off styles).
  if grep -qiE "^#{1,6}[[:space:]].*(Usage|Getting Started)" "$readme" \
     || grep -qiE "^#{1,6}[[:space:]].*Install" "$readme"; then
    log_debug "seed_scan" "docs: README has usage/install sections"
    return 0
  fi
  if (( ${#missing[@]} > 0 )); then
    local rel; rel="$(seed_relpath "$readme")"
    _push_candidate "doc-gap" "document install & usage in README" \
      "\`${rel}\` is missing standard sections (looked for: ${missing[*]}). A reader
cannot tell how to install or run the project." \
      "- [ ] Install section added to ${rel}
- [ ] Usage / Getting Started section added to ${rel}" \
      "" "$(jq -cn --arg f "$rel" '[$f]')" "${rel}|sections" "docs" "P3" "S"
  fi
}

# =========================================================================== #
# SCANNER 4 — dependency drift / advisories (best-effort; non-fatal; SCAN_DEPS=0 skips).
#   Per ecosystem: outdated -> type:chore/P3; known advisory -> type:bug/P1.
#   canonical_key uses ecosystem+package (NOT version) so a still-outdated dep is
#   not refiled every run (architecture §8).
# =========================================================================== #
seed_scan_deps() {
  (( SCAN_DEPS )) || { log_debug "seed_scan" "deps: skipped (--no-deps)"; return 0; }
  log_debug "seed_scan" "deps: drift/advisory probes"

  # --- Node (npm) ----------------------------------------------------------- #
  if [[ -f "${SCAN_ROOT}/package.json" ]] && command -v npm >/dev/null 2>&1; then
    # Advisories first (higher priority). `npm audit --json` is non-fatal here.
    local audit
    audit="$( cd "$SCAN_ROOT" && npm audit --json 2>/dev/null || true )"
    if [[ -n "$audit" ]]; then
      # Group advisories by package name (severity high|critical only).
      local pkgs
      pkgs="$(printf '%s' "$audit" | jq -r '
        (.vulnerabilities // {}) | to_entries[]
        | select(.value.severity=="high" or .value.severity=="critical")
        | .key' 2>/dev/null | sort -u || true)"
      local p
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        _push_candidate "dep-advisory" "security advisory: npm package ${p}" \
          "\`npm audit\` reports a high/critical advisory for \`${p}\`. Upgrade to a
patched version (or replace the dependency)." \
          "- [ ] \`${p}\` upgraded/replaced to a non-vulnerable version
- [ ] \`npm audit\` reports no high/critical advisory for \`${p}\`" \
          "" "[]" "npm|advisory|${p}" "bug" "P1" "S"
      done <<<"$pkgs"
    fi
    # Drift: packages a MAJOR version behind.
    local outdated
    outdated="$( cd "$SCAN_ROOT" && npm outdated --json 2>/dev/null || true )"
    if [[ -n "$outdated" && "$outdated" != "{}" ]]; then
      local majors
      majors="$(printf '%s' "$outdated" | jq -r '
        to_entries[]
        | select((.value.current // "" | split(".")[0]) != (.value.latest // "" | split(".")[0]))
        | .key' 2>/dev/null | sort -u || true)"
      local pk
      while IFS= read -r pk; do
        [[ -z "$pk" ]] && continue
        _push_candidate "dep-drift" "bump npm dependency ${pk} (major behind)" \
          "\`npm outdated\` shows \`${pk}\` is at least one MAJOR version behind latest.
Evaluate and perform a controlled upgrade." \
          "- [ ] \`${pk}\` upgraded with the changelog reviewed for breaking changes
- [ ] Build and tests green after the bump" \
          "" "[]" "npm|drift|${pk}" "chore" "P3" "M"
      done <<<"$majors"
    fi
  fi

  # --- Python (pip) --------------------------------------------------------- #
  if { [[ -f "${SCAN_ROOT}/pyproject.toml" ]] || [[ -f "${SCAN_ROOT}/requirements.txt" ]]; } \
     && command -v pip >/dev/null 2>&1; then
    local pyout
    pyout="$( pip list --outdated --format=json 2>/dev/null || true )"
    if [[ -n "$pyout" && "$pyout" != "[]" ]]; then
      local pypkgs
      pypkgs="$(printf '%s' "$pyout" | jq -r '
        .[] | select((.version|split(".")[0]) != (.latest_version|split(".")[0])) | .name' \
        2>/dev/null | sort -u || true)"
      local pp
      while IFS= read -r pp; do
        [[ -z "$pp" ]] && continue
        _push_candidate "dep-drift" "bump python dependency ${pp} (major behind)" \
          "\`pip list --outdated\` shows \`${pp}\` is at least one MAJOR version behind.
Evaluate and perform a controlled upgrade." \
          "- [ ] \`${pp}\` upgraded with the changelog reviewed for breaking changes
- [ ] Build and tests green after the bump" \
          "" "[]" "pip|drift|${pp}" "chore" "P3" "M"
      done <<<"$pypkgs"
    fi
  fi

  # --- Go ------------------------------------------------------------------- #
  if [[ -f "${SCAN_ROOT}/go.mod" ]] && command -v go >/dev/null 2>&1; then
    if command -v govulncheck >/dev/null 2>&1; then
      local gv
      gv="$( cd "$SCAN_ROOT" && govulncheck -json ./... 2>/dev/null || true )"
      if printf '%s' "$gv" | grep -q '"osv"'; then
        local mods
        mods="$(printf '%s' "$gv" | jq -r 'select(.osv?!=null) | .osv.affected[]?.package.name // empty' 2>/dev/null | sort -u || true)"
        local gm
        while IFS= read -r gm; do
          [[ -z "$gm" ]] && continue
          _push_candidate "dep-advisory" "security advisory: go module ${gm}" \
            "\`govulncheck\` reports a known vulnerability affecting \`${gm}\`. Upgrade to a
patched version." \
            "- [ ] \`${gm}\` upgraded to a non-vulnerable version
- [ ] \`govulncheck ./...\` reports no advisory for \`${gm}\`" \
            "" "[]" "go|advisory|${gm}" "bug" "P1" "S"
        done <<<"$mods"
      fi
    fi
  fi
}

# =========================================================================== #
# SCANNER 5 — --context brain-dump.
#   One candidate per bullet/intent. These are inherently under-specced, so they
#   are filed at status:triage (never auto:eligible) regardless of refinement
#   (decisions.md §3 / spec-conventions §6.3). Default type/priority/size are
#   conservative (chore/P2/M); the classify subagent (if present) may refine.
# =========================================================================== #
seed_scan_context() {
  [[ -n "$CONTEXT_RAW" ]] || { log_debug "seed_scan" "context: none provided"; return 0; }
  local text="$CONTEXT_RAW"
  # @file form: read the file body.
  if [[ "$text" == @* ]]; then
    local f="${text#@}"
    if [[ -f "$f" ]]; then
      text="$(cat -- "$f")"
    else
      log_error "seed_scan" "context-file-missing" "no such file: ${f}"
      return 0
    fi
  fi

  log_debug "seed_scan" "context: splitting brain-dump into bullets"
  # Split into intents: a `- ` / `* ` / `N.` bullet, else one intent per non-empty line.
  local intents intent
  intents="$(printf '%s\n' "$text" \
    | sed -E 's/^[[:space:]]*([*-]|[0-9]+[.)])[[:space:]]+/\n/' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' )"
  while IFS= read -r intent; do
    [[ -z "$intent" ]] && continue
    local norm key title
    norm="$(seed_norm "$intent")"
    key="$norm"   # brain-dump dedup key = normalized bullet text.
    title="${intent:0:70}"
    _push_candidate "brain-dump" "$title" \
      "Operator brain-dump intent (filed via \`--context\`):

> ${intent}

This is under-specced on purpose — a human confirms scope/acceptance before it
becomes \`auto:eligible\`." \
      "- [ ] Scope and acceptance criteria confirmed by a human
- [ ] Restated as a verifiable checklist" \
      "" "[]" "$key" "chore" "P2" "M"
  done <<<"$intents"
}

# =========================================================================== #
# DEDUP ENGINE — fingerprint pre-read + decision.
#
# seed_load_fingerprints reads every existing auto:seeded issue (open+closed)
# ONCE and builds the fingerprint -> {number,state} map in $FP_MAP_JSON. This is a
# read-only gh query (allowed even under --dry-run so the rehearsal is faithful).
# seed_dedup_decision / seed_fp_issue_number are pure lookups in that map.
# =========================================================================== #

# seed_load_fingerprints
#   Populate $FP_MAP_JSON from existing auto:seeded issues. Idempotent; safe under
#   --dry-run. If gh is unauthenticated we cannot dedup, so leave the map empty
#   (every candidate becomes a "create" decision, which --dry-run surfaces harmlessly).
seed_load_fingerprints() {
  if ! gh_auth_ok; then
    log_error "seed_fp" "gh-unauthenticated" "cannot pre-read fingerprints; treating all candidates as new"
    return 0
  fi
  local raw
  raw="$(gh_retry gh.seed_fp_list -- issue list --state all \
          --label "$AUTO_LABEL_SEEDED" --limit 1000 \
          --json number,state,body 2>/dev/null || true)"
  [[ -z "$raw" ]] && { log_debug "seed_fp" "no existing seeded issues"; return 0; }
  FP_MAP_JSON="$(printf '%s' "$raw" | jq -c '
    reduce .[] as $i ({};
      ( $i.body | capture("auto-seed-fp: (?<f>[0-9a-f]{40})").f ) as $fp
      | if $fp == null then .
        else .[$fp] = { number: $i.number, state: ($i.state|ascii_upcase) }
        end)' 2>/dev/null || echo '{}')"
  local known; known="$(printf '%s' "$FP_MAP_JSON" | jq 'length')"
  log_info "seed_fp" "loaded ${known} existing fingerprint(s)"
}

# seed_dedup_decision <fingerprint>
#   Print exactly one of: create | skip-open | skip-closed | reseed-closed.
#   Pure lookup over $FP_MAP_JSON; honors $RESEED_CLOSED for closed matches.
seed_dedup_decision() {
  local fp="$1" hit state
  hit="$(printf '%s' "$FP_MAP_JSON" | jq -c --arg fp "$fp" '.[$fp] // empty')"
  if [[ -z "$hit" ]]; then printf 'create'; return 0; fi
  state="$(printf '%s' "$hit" | jq -r '.state')"
  case "$state" in
    OPEN)   printf 'skip-open' ;;
    CLOSED) if (( RESEED_CLOSED )); then printf 'reseed-closed'; else printf 'skip-closed'; fi ;;
    *)      printf 'skip-open' ;;
  esac
}

# seed_fp_issue_number <fingerprint>
#   Print the existing issue number for a fingerprint, or empty. Pure lookup.
seed_fp_issue_number() {
  printf '%s' "$FP_MAP_JSON" | jq -r --arg fp "$1" '.[$fp].number // empty'
}
