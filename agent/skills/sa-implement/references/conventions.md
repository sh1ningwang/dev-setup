# /auto — Conventions (human + machine reference)

> Authority order: `decisions.md` (LOCKED) > `architecture.md` > `critique.md` > the
> `spec-*.md` lenses. This file restates the conventions the engine enforces at
> runtime. Every value here mirrors `lib/constants.sh`; where this prose and
> `constants.sh` ever disagree, **`constants.sh` wins** (it is the string source of
> truth and is parsed by the scripts).

---

## 1. Branch naming

Pattern (`AUTO_BRANCH_PREFIX` + `<type>` + `<issue#>` + `<slug>`):

```
auto/<type>/<issue#>-<slug>
```

- `<type>` ∈ `feat fix chore spike refactor docs` (`AUTO_BRANCH_TYPES`). The branch
  `<type>` is derived from the issue's `type:*` label (`type:feature → feat`,
  `type:bug → fix`, the rest map 1:1).
- `<issue#>` is the GitHub issue number the branch closes (one issue → one branch → one PR).
- `<slug>` is the issue title lowercased, non-alphanumeric runs collapsed to `-`,
  leading/trailing `-` trimmed, truncated to `AUTO_SLUG_MAXLEN` (40) chars.

  ```bash
  slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40
  }
  ```

- **Always cut from `origin/develop-auto`** (`AUTO_BASE_BRANCH`):
  `git fetch origin && git switch -c "$branch" origin/develop-auto`.
- Examples: `auto/feat/42-todo-scanner`, `auto/fix/57-null-guard-on-empty-input`.

`AUTO_BASE_BRANCH` is a **hard lock** (decisions.md D1). No argument, config key, or
environment variable can change the base or the branch-from point. The PR-create path
verifies the base three times (see §4).

---

## 2. Commit rules (decisions.md §5; enforced by `commit-gate.sh`)

Every commit is routed through `bin/commit-gate.sh` — the engine never calls raw
`git commit`. The gate is a hard gate (reject, not warn):

1. **No `Co-Authored-By:` lines, ever.** The gate greps the message (case-insensitive,
   line-anchored) and rejects on any hit. Several agent CLIs inject this trailer by
   default; the gate closes that leak. The squash-merge body is additionally scrubbed
   empty (`--body ""`) so nothing survives the squash even if a trailer slipped through.
2. **Conventional Commits subject.** First line must match
   `^(feat|fix|chore|spike|docs|test|perf|refactor)(\([a-z0-9._-]+\))?!?: .+`,
   subject ≤ 72 chars, imperative mood. Atomic: one logical change per commit.
3. **gitleaks clean.** `gitleaks protect --staged --redact` must pass. Preflight A10
   hard-asserts `gitleaks` is installed (`EX_PREFLIGHT_GITLEAKS=68`) so the scan is never
   silently skipped. The `review-secrets-leaks` role is a **second, independent** scan at
   a different granularity (manual review + gitleaks) — deliberately complementary.
4. **Buildable per commit.** `bin/build-check.sh` runs the project's fast build/test gate
   (auto-detected: `npm run build`/`test`, `pytest -x -q`, `go build ./...`, `make check`,
   …; overridable in `auto.config.json`). A staged tree that fails the fast gate is
   rejected; the engine must fix-forward before committing. Full PR CI remains the
   authoritative gate; this catches broken intermediate commits early.

Merge method is `squash` (`AUTO_MERGE_METHOD`): one issue → one PR → one atomic
conventional commit on `develop-auto`. Subject = PR title; body scrubbed to empty.

---

## 3. Label taxonomy (decisions.md §3 — single source of truth)

The only valid label set. Defined as strings in `lib/constants.sh`; every query uses
these exact names; `templates/.github/auto/labels.json` matches them exactly. Do **not**
introduce `auto:queued`, `auto:in-progress`, `auto:blocked`, `auto:followup`,
`auto:size/*`, a flat `blocked`, `auto-seeded` (hyphen), `type:test`, `type:perf`, or any
`status:*`/`auto:*` duplicate. Eligibility is `auto:eligible` vs `auto:hold`.

| Group | Label | Meaning |
|-------|-------|---------|
| **Control (`auto:*`)** | `auto:eligible` | /auto MAY pick this issue. |
| | `auto:claimed` | A lease is held (paired with a lease comment + assignee). Do not pick up. |
| | `auto:hold` | Human-gated; /auto must NOT pick (used for escalations). |
| | `auto:stop` | Kill-switch. On the pinned `#auto-control` issue **only**. Halts pickup until a human removes it. |
| | `auto:seeded` | Issue was filed by `--seed`; carries a hidden fingerprint marker. |
| **Lifecycle (`status:*`)** | `status:triage` | Newly filed (often by `--seed`). Awaiting prioritization/sizing; not auto-pickable. |
| | `status:ready` | Fully specced (size + priority + acceptance criteria). Ready to implement. |
| | `status:in-progress` | Implementation underway in an /auto iteration. |
| | `status:in-review` | PR open against `develop-auto`, in bounded review rounds. |
| | `status:done` | PR merged to `develop-auto`. Issue closed by `Closes #N`. |
| | `status:blocked` | Failed or blocked; needs a human. /auto will not proceed. |
| **Priority** | `priority:P0` | Critical (build broken, security, data loss). Highest. |
| | `priority:P1` | High. This cycle. |
| | `priority:P2` | Normal. Default. |
| | `priority:P3` | Low / nice-to-have. Picked up only when the queue is otherwise empty. |
| **Type** | `type:feature` | New user-facing capability. |
| | `type:bug` | Defect: behavior diverges from intent/spec. |
| | `type:chore` | Maintenance: deps, config, housekeeping; no behavior change. |
| | `type:spike` | Time-boxed investigation; output is findings, not shipped behavior. |
| | `type:refactor` | Internal restructuring; no functional change. |
| | `type:docs` | Documentation-only change. |
| **Size** | `size:S` | Small: < ~1h, single file/concern. Informational scope hint. |
| | `size:M` | Medium: a few files, one concern. Informational scope hint. |
| | `size:L` | Large: cross-cutting, multiple modules. Informational scope hint. |
| | `size:XL` | Extra-large: should usually be split. Informational; same consensus protocol runs regardless. |

**Eligibility predicate.** /auto picks an issue iff: it is OPEN, carries `auto:eligible`,
does **not** carry `auto:hold` / `auto:claimed` / `status:in-progress` / `status:blocked`,
and matches the `--theme/--label` filter when supplied. `status:triage` items are never
auto-pickable until a human promotes them to `status:ready` + `auto:eligible`.

---

## 4. Base-lock & CI parity (decisions.md D1, D2; enforced by `auto-pr-create.sh` / `ci-parity-check.sh`)

**Base hard-lock.** Every PR /auto opens targets `develop-auto` and nothing else. Three
guards in `bin/auto-pr-create.sh`:

1. **Pre-create:** requested base must equal `AUTO_BASE_BRANCH` — else `EX_PR_BASE_LOCK=70`.
2. **Branch origin:** head must derive from `origin/develop-auto`
   (`git merge-base --is-ancestor`) — else `EX_PR_PUSH=71`.
3. **Post-create verify:** re-read `gh pr view --json baseRefName`; if base drifted,
   close the PR immediately — else `EX_PR_VERIFY=72`.

Defense-in-depth: the optional server-side `auto-base-guard.yml` (user adds it at
bootstrap) fails any auto-authored PR whose base ≠ `develop-auto`. It is marked
`# auto:exclude-from-parity` so `ci-parity-check.sh` ignores it.

**CI parity** (decisions.md D2): the set of **required status checks** GitHub demands on a
PR → `develop-auto` must be byte-identical to the set on a PR → `develop`. `ci-parity-check.sh`
verifies three layers (triggered-check-name parity, required-status-check parity, and
`required ⊆ triggered` on `develop-auto`) and exits `EX_CHECK_FAIL=2` on any divergence,
printing the exact diverging element. Parity binds **checks, not review count**
(decisions.md D6: `develop-auto` requires ZERO approving reviews).

---

## 5. Auto-merge & the green floor (decisions.md D3)

- **Method:** squash, subject = PR title, body scrubbed empty.
- **Mechanism:** local poll-then-merge. Poll `gh pr checks --required` every
  `CHECK_POLL_INTERVAL` (30s) up to `CHECK_POLL_TIMEOUT` (3600s), then escalate.
  Platform `--auto` is an optional accelerator only.
- **Green floor (`AUTO_GREEN_FLOOR=1`):** refuse to merge if the `develop-auto`
  required-check set is **empty** — a misconfigured repo must not ship unverified code
  (`EX_PR_GREEN_FLOOR=74`; preflight A7' aborts at start with `EX_PREFLIGHT_GREENFLOOR=66`).
- **Flaky budget:** `FLAKY_RETRY_MAX=2` reruns of only failed required checks, then
  escalate. Never merge red (`EX_PR_NOT_GREEN=73`).
- **Conflicts:** `gh pr update-branch` (merge-from-base, **no force**) only. Force-push is
  forbidden everywhere (`AUTO_ALLOW_FORCE_PUSH=0`); an unresolved conflict escalates
  (`EX_PR_CONFLICT=75`).

---

## 6. Size → engine routing (decisions.md §5 / architecture §5.1)

Every issue runs the SAME **consensus protocol** — `size:*` is **informational only**, it no
longer selects an engine. All roles run as **subagents only** (no agent teams), flat /
depth-1; each triplet is spawned **in parallel** so its members are **isolated** (a member
sees only the `GoalArtifact` + scoped diff, never its peers' output). The session sequences
the gates; subagents never recurse or message peers. (Full detail: architecture §5.1.)

1. **intake** — build the `GoalArtifact` (goal, constraints, `success_criteria` = the
   acceptance criteria, iteration_question).
2. **DESIGN consensus** — `solver-minimal` / `solver-structural` / `solver-delete` →
   `meta-judge` (design truth table) → ONE concrete plan, or escalate.
3. **implement** — `implement-backend` / `implement-frontend` builds ONLY the approved plan;
   `debug` only if the build/tests are red. Every commit goes through `commit-gate.sh`.
4. **REVIEW consensus** — `reviewer-requirements` / `reviewer-quality` / `reviewer-tests` →
   `meta-judge` (review truth table) → `done` / `fix`. `review-secrets-leaks` is a standing
   hard gate. **Requirements conformance is mandatory for `done`** ("100% meets requirements").
5. **fix loop** — bounded by `AUTO_ROUNDS_CEILING` (5); on exhaustion (or a design
   `escalate`) → human-gated escalation. `write-documentation` persists any spec/doc the
   gates produce. `auto.config.json` may tune the round ceiling, not the consensus shape.

**Write-access enforcement (`lib/roles.sh` classification, mirrored in each `agents/<role>.md` `tools:`).**
Each role is spawned as a native `auto:<role>` subagent whose `tools:` frontmatter fixes its
grant, so a read-only role physically cannot write:

- **Write-capable (3 roles only):** `implement-backend`, `implement-frontend`,
  `write-documentation` → `Read, Edit, Write, Bash, Grep, Glob`.
- **Read-only (9 roles):** all analyze/architect/review/debug roles → `Read, Grep, Glob`
  (no Edit/Write/Bash — they cannot mutate the repo or run commands). They emit findings on
  stdout; the orchestrator feeds them the scoped diff, and persistence is delegated to
  `auto:write-documentation`.
- An unknown/unscoped spawn defaults to **read-only** (fail-safe).

---

## 7. Bounded-review policy (decisions.md §5 / architecture §5.4)

Each review round:

1. Collect all **blocking** findings from the review fan-out (a finding is blocking only
   if its review skill marks it so; nits are recorded, never gate the merge).
2. The implementer addresses them in new atomic commits (each routed through the gate).
3. Re-run the reviews.

**Success** = zero blocking findings **AND** CI 100% green → eligible for auto-merge.

**Exhaustion** (rounds hit the per-size default, capped at 5) → escalate (§8). No
infinite loop — this is the 24/7 safety valve.

---

## 8. Escalation policy (decisions.md §2, §3 / architecture §3.4)

Escalation is **human-gated** — escalated follow-ups never re-enter the autonomous queue
automatically. On exhausted rounds or a hard failure, /auto:

1. Posts a PR comment summarizing the unresolved findings round-by-round.
2. Files a **follow-up issue** labeled `auto:hold` + `status:triage` + a `type:*`
   (NOT `auto:eligible`), titled `follow-up(#N): unresolved review findings`, body listing
   each open finding and a link to the PR/branch.
3. Relabels the original issue `status:blocked`, drops `auto:claimed`, and leaves the PR as
   a **draft** (never merged).
4. Releases the claim and moves on.

A run-level escalation counter is bounded by `MAX_ESCALATIONS` (5,
`AUTO_STOP_REASON_ESCALATIONS`): if escalations spike, the run hard-stops via the gate
rather than churning the backlog 24/7. (`auto:queued`/`auto:followup` re-eligible variants
from other lenses are rejected.)

---

## 9. Account & identity

All git/gh operations run as **the installing user's ACTIVE local gh account**: preflight
A10 resolves the active login (`gh api user`), snapshots it to `.auto/.account`, and every
mutation boundary re-asserts it (`EX_PREFLIGHT_ACCOUNT=69` on drift). The engine **never runs
`gh auth switch`** and never mutates global gh/git state — this is what makes concurrent loop
instances on different project directories safe. `AUTO_GH_ACCOUNT` is an OPTIONAL operator pin:
when exported, preflight asserts the active login matches and aborts otherwise (the human does
the switching). Commit identity = the user's own git config; only when git has no identity does
the engine derive the GitHub noreply form (`<id>+<login>@users.noreply.github.com`), and
`AUTO_GIT_USER_NAME` / `AUTO_GIT_USER_EMAIL` env overrides win over both.
`develop-auto` requires ZERO reviews, so the second-approver path (`AUTO_APPROVER_TOKEN`,
env/keychain only — never committed) is reserved/unused in v1; preflight A6 aborts
(`EX_PREFLIGHT_REVIEW=65`) rather than relying on it.

See `references/state-model.md` for the lease/kill-switch contracts and
`references/architecture.md` for the engine design + plugin distribution.
