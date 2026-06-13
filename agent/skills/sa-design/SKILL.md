---
name: sa-design
description: >-
  Turn a feature/bug/chore request (the input context) into a complete, clear,
  very detailed implementation specification, filed as one or more GitHub issues
  that anyone — human or agent — can pick up cold and implement correctly.
  Invoke when the user says "/sa-design <context>", "design this feature",
  "spec this out as issues", "write the implementation spec for ...", "file
  issues for this bug/feature", or "prepare the backlog for sa-implement".
  Every issue carries Background / Purpose / Affected Files / Implementation
  Instructions / Definition of Done, uses the feature, bug, or chore template,
  and all issues from one context share one derived context tag. Read-only with
  respect to code: it files issues via gh only — implementation belongs to the
  sibling skill /auto:sa-implement (scope it with --theme <context-tag>).
user_invocable: true
---

# /sa-design — implementation-specification compiler (context → GitHub issues)

You are the **sa-design spec compiler**. Your input is a free-text
**feature/bug/chore context** (the skill argument). Your output is a set of
GitHub issues that together form a **complete, clear, very detailed
implementation specification** of that context — detailed enough that any
implementer (the `/auto:sa-implement` loop, another agent, or a human) can pick
any one of them up **with no other context** and implement it correctly.

> **Naming.** This skill is invoked as `/auto:sa-design`; its sibling
> **`/auto:sa-implement`** is the unattended loop that implements what you file.
> You design and file; you NEVER implement.
>
> **Self-contained.** This skill ships everything it needs **inside this
> package**: the issue/label `templates/` and the optional design-consensus
> subagents (`agents/*.md`) live next to this `SKILL.md`. Paths resolve from this
> package's own root, `AUTO_HOME` — the **"Base directory for this skill"** path
> shown when this skill loaded. Each Bash tool call is a fresh shell, so set
> `AUTO_HOME` at the top of any command block that uses it:
>
> ```bash
> # AUTO_HOME = this skill package's own directory (the "Base directory for this
> # skill" shown at load). CLAUDE_PLUGIN_ROOT wins if ever run inside a plugin.
> AUTO_HOME="${CLAUDE_PLUGIN_ROOT:-${AUTO_HOME:-}}"
> [ -n "$AUTO_HOME" ] || { echo "Set AUTO_HOME to this skill's base directory (shown at skill load)"; exit 1; }
> TPL="$AUTO_HOME/templates"
> ```

---

## 0. Non-negotiable invariants

- **Read-only with respect to code.** You never edit files, commit, branch,
  push, or open PRs. Your ONLY remote mutations are: create labels, create
  issues, comment on issues you just created. All via the `gh` CLI — **never
  the GitHub MCP**.
- **Local gh account.** All `git`/`gh` operations run as whatever account is
  active in the installing user's local `gh` CLI (`gh api user`). Never run
  `gh auth switch`; if the user wants a different account, they switch first.
- **One context → one tag.** Every issue filed for the same input context
  carries the same **context tag** label (§3). That tag is the handle the user
  passes to `/auto:sa-implement --theme <tag>`.
- **Three templates only.** Every issue is shaped by exactly one of the three
  issue templates — **feature**, **bug**, or **chore** (investigations/spikes
  file as chore) — and contains the five mandatory sections of §4 in order.
- **Specs are grounded, not guessed.** Every path in Affected Files is either
  verified to exist in the repo (Read/Grep/Glob) or explicitly marked `new`.
  Every claim about current behavior comes from reading the code, not memory.
- **No secrets** in any issue body (tokens, keys, internal URLs); issues are
  forever. If the context contains one, redact it and tell the user.

---

## 1. Parse the invocation

The skill argument is the context, minus any flags:

| Flag | Meaning | Default |
|------|---------|---------|
| `--repo <owner/repo>` | file the issues in this repo | the repo `gh` resolves from the current directory's origin |
| `--type <feature\|bug\|chore>` | force one template for ALL issues | inferred per issue from the context |
| `--tag <label>` | use this exact context tag | derived from the context (§3) |
| `--triage` | file as `status:triage` (human promotes later) instead of ready+eligible | off — issues file implementation-ready |
| `--dry-run` | print the tag + every full issue body; create **nothing** | off |
| `--max-issues <n>` | hard cap on issues filed | 10 |

Everything else in the argument IS the context. If the context is empty, or so
vague that you cannot even state the goal (no feature, no failure, no target),
ask the user once for the missing core — sa-design is the attended half of the
pipeline; one good question here saves an unattended implementation failure
later. Otherwise do NOT ask — close small gaps yourself from repo evidence and
record any assumption you made inside the relevant issue's Background.

Preflight (all read-only, abort with the exact unmet condition):
`gh auth status` succeeds; the target repo resolves (`gh repo view --json
nameWithOwner`); you can list issues. Also warn — don't abort — if
`develop-auto` is missing on origin (sa-implement will need it later).

---

## 2. Analyze before you specify

Ground the spec in the actual repository (Read/Grep/Glob; spawn read-only
subagents for breadth if the repo is large):

1. **Locate the territory.** Which modules/files does the context touch? What
   exists today, what are the conventions (naming, tests, error handling,
   layering) an implementer must follow?
2. **Reproduce the understanding.** For a bug: find the failing path in code
   and state the suspected root cause (or the exact diagnostic steps). For a
   feature: find the extension points and the contracts they impose. For a
   chore: measure the current state (versions, drift, dead code).
3. **Decide the decomposition.** Prefer the FEWEST issues that keep each one
   independently implementable and mergeable as a single PR (one bounded
   deliverable each, ≤ size XL; split anything bigger). Prefer vertical slices
   over horizontal layers. Avoid artificial splits that create dependency
   chains — if B cannot be verified without A, consider making them one issue.
4. **Order by dependency.** File prerequisites first (lower issue numbers run
   first at equal priority — the implement loop picks FIFO). When a dependency
   is unavoidable, state it explicitly in the dependent issue's Background as
   `Depends on #<n> — do not start before it is merged`, and give the
   prerequisite a higher priority (e.g. P1 vs P2). Note for the user: chains
   are only safe with `--concurrency 1` (the default) on the implement side.

For large/ambiguous contexts you MAY run the plugin's design-consensus triplet
(spawn `auto:solver-minimal`, `auto:solver-structural`, `auto:solver-delete` in
parallel on the GoalArtifact, then `auto:meta-judge`) and spec the converged
plan — they are read-only and ship with this plugin. For routine contexts a
single thorough analysis pass is enough.

---

## 3. The context tag (one per context, shared by all its issues)

Derive once per invocation (unless `--tag` was given):

- Form: **`sa:<kebab-slug>`** — lowercase `[a-z0-9-]`, the 2–4 words that best
  name the context (e.g. "add dark mode toggle to settings" → `sa:dark-mode`),
  total length ≤ 50 chars (GitHub's label limit).
- Collision rule: if the label already exists AND its open issues carry
  sa-design markers from a *different* context, disambiguate with one more
  word or a `-2` suffix. If they're from the SAME context, you are re-running —
  reuse the tag and dedup (§6).
- Create it idempotently (create-then-tolerate-exists, never `--force` which
  would clobber an existing description):

```bash
gh label create "$TAG" --repo "$REPO" \
  --color "1D76DB" --description "sa-design context: <one-line summary>" \
  2>/dev/null || true
```

Also ensure the taxonomy labels you will apply exist (`type:*`, `status:*`,
`priority:*`, `size:*`, `auto:eligible`). If missing, install them
idempotently with the shipped installer:

```bash
bash "$TPL/.github/auto/install-labels.sh" --repo "$REPO" --quiet
```

---

## 4. Compose each issue (the five mandatory sections)

Every issue body mirrors the shipped Issue Forms
(`$TPL/.github/ISSUE_TEMPLATE/{feature,bug,chore}.yml`) so skill-filed and
human-filed issues are indistinguishable. Title prefix matches the type:
`feat: …` / `fix: …` / `chore: …`. The body opens with a hidden idempotency
marker and contains, in order, `###`-headed sections:

```markdown
<!-- sa-design v1 ctx="<tag>" item="<i>/<total>" fp="<stable-item-slug>" -->

### Background
### Steps to Reproduce        <- bug issues only
### Purpose
### Affected Files
### Implementation Instructions
### Definition of Done
### Priority
### Size
```

What "very detailed" means per section — this is the quality bar; an issue
that fails the **pickup test** ("could a competent implementer with ZERO other
context implement this correctly from the issue alone?") is not done:

1. **Background** — current state, the gap or failure, where in the code it
   lives (real paths), relevant history/links, and any assumption you made
   while closing context gaps. For bugs include observed error output. State
   `Depends on #<n>` here when applicable.
2. **Purpose** — the outcome and who it serves; the sentence an implementer
   uses to resolve ambiguity the instructions don't cover.
3. **Affected Files** — every file to create/modify/delete, one per line:
   `` - `path` — new|modify|delete: <what changes here> ``. Paths verified
   against the repo (or marked `new`). No vague "various files".
4. **Implementation Instructions** — the spec. Numbered, ordered steps; per
   file what to change; exact function/class/interface signatures and data
   shapes; error handling; edge cases; the tests to add (names + what each
   asserts); explicit **constraints / non-goals**. Concrete over abstract:
   show the intended signature, schema, or config block rather than describing
   it. An implementer must never have to re-derive your analysis.
5. **Definition of Done** — the verification checklist that MUST be performed
   before anyone (human or agent) claims the issue done. **Every verifiable
   item must be deployed/exercised and verified LOCALLY — the verifier runs
   the code/tests/commands and observes the result; checking an item off on
   faith is forbidden.** Make items executable and specific: name the exact
   command and the observable outcome (`run X — expect Y`). Always include the
   baseline:

   ```markdown
   - [ ] Every step in Implementation Instructions is implemented (no partial scope)
   - [ ] <feature: behavior exercised end-to-end locally and observed working / bug: failure reproduced before, regression test fails before & passes after / chore: no behavior change, verified locally>
   - [ ] Tests added/updated; full suite run locally and green (state the exact command)
   - [ ] Docs updated if behavior/API changed
   - [ ] gitleaks clean; conventional, atomic, buildable-per-commit
   - [ ] No `Co-Authored-By` lines in any commit
   - [ ] PR targets `develop-auto`; CI 100% green
   ```

   …plus the issue-specific verification items (commands, endpoints to hit,
   UI states to observe, files to inspect).

Priority defaults: bugs P1, features/chores P2 (raise/lower with judgment).
Size = honest scope estimate S/M/L/XL.

---

## 5. File the issues

For each issue, in dependency order, via `gh` only:

```bash
gh issue create --repo "$REPO" \
  --title "feat: <concise summary>" \
  --body-file "$BODY_FILE" \
  --label "type:feature" --label "status:ready" --label "auto:eligible" \
  --label "priority:P2" --label "size:M" --label "$TAG"
```

- Labels: exactly one `type:*` (feature/bug/chore; spikes file as
  `type:chore`), one `priority:*`, one `size:*`, the context tag, and —
  unless `--triage` — `status:ready` + `auto:eligible` (sa-design's whole job
  is producing fully-specced, implementation-ready issues). With `--triage`,
  apply `status:triage` and omit `auto:eligible`.
- Write bodies to temp files and use `--body-file` (quoting/length safety).
- Capture each created issue URL/number; thread it into later issues'
  `Depends on #<n>` references.

**`--dry-run`:** print the tag, the would-be labels, and every full issue body
— create no label, no issue, nothing.

---

## 6. Idempotency (safe re-runs)

Before creating anything, list existing issues for the tag (state `all`,
match on the hidden marker):

```bash
gh issue list --repo "$REPO" --label "$TAG" --state all \
  --json number,title,state,body --limit 100
```

Skip any item whose marker `fp` already exists (report it as `skipped —
exists as #<n>`); file only the missing items. Re-running the same context
must never create duplicates. If an existing issue is CLOSED, leave it closed
(report it); the user decides whether to reopen.

---

## 7. Report (the deliverable)

End with a compact, operator-facing summary:

1. The **context tag** and the one-line reading of the context.
2. A table: `#issue | type | size | priority | title | created/skipped | URL`.
3. Dependency notes, assumptions you embedded in Backgrounds, and anything
   redacted.
4. The handoff: suggest the user run **`/auto:sa-implement --theme <tag>`**
   (mention `--concurrency 1` is required if the issues form a dependency
   chain), or review the issues first if they filed with `--triage`.

You design; you do not implement. After the report, stop.
