# Standing context for AI coding agents in this repository

This file is **static conventions only**. The live work queue, run state, and
priorities are **not** here — they live in **GitHub issues, labels, and PRs**
(`sa-design` files them; `sa-implement` reads and works them at
runtime). Do not maintain a task list in this file.

Read by the AI coding agent working this repo. Keep it short, durable, and
rule-shaped. `sa-implement` installs/updates it via the `auto:write-documentation` role inside
a normal PR — never a direct push.

---

## Non-negotiable rules

These are hard invariants. `sa-implement`'s deterministic gates enforce them; never work
around a gate.

- **Base branch is locked to `develop-auto`.** Every PR you open targets
  `develop-auto` and nothing else — never `main`, `develop`, or a feature branch.
  Humans promote `develop-auto` → `develop` → `main`.
- **No force-push, ever.** Not on any branch, not with `--force-with-lease`.
  Resolve conflicts with `gh pr update-branch` (merge-from-base) only.
- **No `Co-Authored-By` lines in any commit message.** The commit gate rejects
  them; the squash merge body is scrubbed empty as a second line of defense.
- **Conventional Commits**, atomic, and **buildable per commit**: every commit
  builds and passes the fast gate independently (clean bisect). Subject format:
  `type(scope): subject` (≤ 72 chars, imperative).
- **No hardcoded secrets.** Tokens/keys live in the environment or keychain only,
  never in code or config. `gitleaks` scans every commit (see `.gitleaks.toml`).
- **One small PR per issue.** Keep diffs scoped. If work outgrows its `size:*`
  label, stop and escalate rather than ballooning the PR.

---

## Branch & PR conventions

- **Branch naming:** `auto/<type>/<issue#>-<slug>` cut from `origin/develop-auto`.
  `<type>` ∈ {feat, fix, chore, spike, refactor, docs}. `<slug>` is the lowercased
  title with non-alphanumerics collapsed to `-`, trimmed to 40 chars.
- **PR title:** `type(scope): summary (#N)`. PR body includes `Closes #N`.
- **Merge:** squash, with the subject = PR title and an empty body.
- **CI parity:** CI on PRs → `develop-auto` is byte-identical to CI on PRs →
  `develop`. Do not add a workflow that only runs on one of the two branches.
  Auto-infrastructure workflows are exempted via a `# auto:exclude-from-parity`
  marker on their first line.

---

## Labels (the issue state machine)

The canonical taxonomy lives in `.github/auto/labels.json`. Summary:

- **Control (`auto:*`)** — `auto:eligible` (pickable), `auto:claimed` (leased),
  `auto:hold` (human-gated, do not pick), `auto:stop` (kill-switch, on the pinned
  `#auto-control` issue only).
- **Lifecycle (`status:*`)** — `triage` → `ready` → `in-progress` → `in-review`
  → `done`; plus `blocked`.
- **Priority** — `priority:P0..P3` (P0 highest). **Type** — `type:{feature,bug,
  chore,spike,refactor,docs}`. **Size** — `size:{S,M,L,XL}` (informational scope hint).

`sa-implement` only picks an issue that is `auto:eligible` + `status:ready` and not held,
claimed, or blocked. Missing/ambiguous size defaults to `L` (informational only).

---

## Roles & write access

When `sa-implement` fans out to role subagents, write access is enforced by role:

- **May write files:** `implement-backend`, `implement-frontend`,
  `write-documentation`.
- **Read-only (emit findings; cannot write):** the consensus design solvers
  (`solver-minimal` / `-structural` / `-delete`), the `meta-judge`, the review triplet
  (`reviewer-requirements` / `-quality` / `-tests`), `debug`, and `review-secrets-leaks`.
  Persistence they need is delegated to `write-documentation`.

`sa-implement` decides **what to build** (design consensus) and **whether it is done** (review
consensus, requiring 100% of the issue's Definition of Done — every verifiable item
exercised and verified locally, never checked off on faith) by biased
independent-subagent vote — never a single agent. `size:*` is informational; the same
protocol runs for every issue.

---

## Stopping `sa-implement`

Add the `auto:stop` label to the pinned `#auto-control` issue, **or** create the
file `.auto/STOP` on the `develop-auto` branch. Either halts pickup within ~20s
and persists until a human clears it. See `.github/auto/README.md` for details.
