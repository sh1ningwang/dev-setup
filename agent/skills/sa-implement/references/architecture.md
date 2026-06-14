# `/auto` — Autonomous 24/7 Repository-Evolution Skill — Design Document

> An **agent-agnostic skill package** whose implementation loop is the slash command **`/sa-implement <repo-url> <gh-account>`**. Given a GitHub-issue-backed backlog, it autonomously evolves a repository until the user stops it. It is **not** a platform; it is a `git`+`gh`-only deterministic shell engine plus host-native **subagents**, driven by **two cooperating processes**: a long-running, deterministic **bash daemon** `bin/auto-daemon.sh` that owns the loop's cadence and triggering, and an interactive **agent session** (host-neutral: OpenCode, Codex, or Claude Code) that is the cognitive worker. The session performs every git/GitHub mutation through the verb layer `bin/auto-api.sh` — it never calls `git`/`gh` directly. `AUTO_HOME` (the skill package's own base directory, set per the SKILL.md instructions) resolves the engine scripts. The package also bundles a companion skill, **`/sa-design`**, which compiles a feature/bug/chore context into the fully-specced, context-tagged issues this loop consumes (`--theme <tag>`). The daemon performs exactly one `gh auth switch` to the **operator-supplied account** at start, then snapshots and hard-refuses drift (see §6.4).

---

## 0. Reading guide & status of this design

This document is **implementation-ready** and **reflects every hard constraint** (numbered HC1–HC8 below). It also **resolves the cross-lens contradictions** surfaced in review and **flags the items that must be confirmed by the user** (see §13 and the `openQuestionsForUser` list). Where the research lenses disagreed, this doc picks **one** authoritative answer and states why; the scripts are written against that single answer.

### Hard constraints (restated, binding)
- **HC1 Branching/autonomy**: origin must have `develop` AND `develop-auto`. Every PR `/auto` opens targets **only** `develop-auto` (hard lock). PRs→`develop-auto` may auto-merge **only** when CI is 100% green. CI on PRs→`develop-auto` is **byte-identical** to CI on PRs→`develop`. Humans promote `develop-auto`→`develop`.
- **HC2 Host-neutral + stateless**: an agent-agnostic skill package. **Host-native subagents only** (no `TeamCreate`/agent-teams/`SendMessage`) — chosen NOT for portability but because every iteration must reconstruct cold from GitHub, and a long-lived in-memory agent-team cannot survive a `kill -9` / daemon resurrection. Deterministic logic is shell using **only `git`+`gh`**. The GitHub MCP and any host-specific scheduling tool are **never** hard dependencies; the **bash daemon `bin/auto-daemon.sh`** is the single continuity mechanism (it owns the loop's cadence, polls the issue queue, and triggers the agent session over FIFOs).
- **HC3 Preflight aborts**: unmet prereqs → report the exact unmet condition and **terminate**, waiting for the user. Never silently create `develop-auto`.
- **HC4 Engine**: **consensus-gated** — biased independent solvers reach the implementation plan (design consensus → meta-judge), then biased independent reviewers verify it (review consensus → meta-judge), same protocol every issue. Fix loop **bounded** (`AUTO_ROUNDS_CEILING` + escalate-to-new-issue fallback). `size:*` is informational, not an engine selector.
- **HC5 Continuity**: the deterministic **bash daemon `bin/auto-daemon.sh`** is the single continuity mechanism. It is report-driven while work exists (pushes a round, then blocks awaiting the session's report) and idle-polls every ~15 minutes only when the queue is empty.
- **HC6 Commits**: conventional, atomic, buildable-per-commit, gitleaks scan, **no `Co-Authored-By`**. Branch `auto/<type>/<issue#>-<slug>` from `develop-auto`. One small PR per issue.
- **HC7 State externalization**: GitHub issues/labels are the durable queue+memory; local context disposable. One bounded deliverable (one issue) per iteration.
- **HC8 Args**: `--duration/--until`, `--theme/--label`, `--max-prs`, `--max-escalations`, plus a kill-switch flippable from anywhere.

### Environment facts (verified at design time; historical)
- Repo `/Users/chronoai/code/personal/auto` was **greenfield** at design time: no commits, no `develop`/`develop-auto`, no `.github/workflows`, no branch protection.
- The host keyring may hold multiple authenticated `gh` accounts, so **account selection must be deterministic**. The operator passes the target account as the `<gh-account>` argument; the daemon performs **exactly one `gh auth switch --user <account>` at start** (the argument IS the authorization to switch), then the engine snapshots the resolved account and hard-refuses any later mid-run drift (see §6.4).
- Present: `git`, `gh`, `jq`, `python3`, `gitleaks` (`/opt/homebrew/bin/gitleaks`), `node`. **Absent: `yq`** → workflow YAML parsing uses `python3` (PyYAML or vendored `miniyaml.py`); `yq` is an optional accelerator only.
- Distribution: a host-neutral **skill package** — a directory containing `SKILL.md` + `bin/` + `lib/` + `agents/` + `references/` + `templates/`, with `AUTO_HOME` set to that base directory per the SKILL.md instructions. It exposes `/sa-implement` and `/sa-design`. It is not a plugin and has no marketplace/registration step.

---

## 1. System overview

`/sa-implement` is driven by **two cooperating processes** over a deterministic engine:

1. **Bash daemon — `bin/auto-daemon.sh` (owns the loop's cadence & triggering).** A long-running, deterministic shell process. At start it switches `gh` to the operator-supplied account (one `gh auth switch`), runs preflight, then **polls the GitHub issue queue** and **triggers the agent session**. Pacing is **report-driven while work exists** (it pushes a round, then blocks awaiting the session's report) and **idle-polls every ~15 minutes** only when the queue is empty. It talks to the session over two FIFOs under `.auto/daemon/`:
   - `work.fifo` (daemon→session): `ROUND <n> <queue-json>` or `STOP <reason>`.
   - `report.fifo` (session→daemon): `REPORT result=<r> issue=<N>`.
   The daemon only **surfaces the prioritized candidate queue**; it does not pick the issue.
2. **Agent session — the cognitive worker (host-neutral: OpenCode, Codex, or Claude Code).** It reads a round, **LLM-PICKS** which issue to do (the agent decides; the daemon merely surfaces candidates), runs the consensus protocol via the **host's native subagents**, and performs **every git/GitHub mutation through the verb layer `bin/auto-api.sh`** (verbs: `queue`/`prep`/`commit`/`finish`/`escalate`/`release`/`kill-check`/`status`). It **never calls `git`/`gh` directly**.

**Deterministic engine (shell, `git`+`gh` only).** Preflight, queue selection, claim/lease, branch policy, commit gate, gitleaks, PR creation (base-locked), CI-parity, auto-merge-when-green, escalation, kill-switch, state. Every mutating/safety step is here, reached only through `bin/auto-api.sh`; the session **cannot bypass it** (it is also backed server-side by `develop-auto` branch protection + the `auto-base-guard` CI).

**Role subagents (host-native `agents/*.md`).** The 12 roles ship in the package and are spawned by the **host's native subagent mechanism**; each carries its own `tools:` grant (writers get Edit/Write; reviewers are read-only). No adapter, no injected prompt fragments. *(A fallback for hosts without native subagents — the daemon spawning extra agent processes to vote in consensus — exists but is **to be wired later**; the primary path uses native subagents.)*

The **state machine** lives in GitHub (issues + labels + PRs) per HC7. Local files under `.auto/` are **disposable cache** and are **never committed**.

### High-level loop (one iteration = one issue)
```
daemon: gh auth switch --user <account> → preflight → poll queue
  ── work.fifo: ROUND <n> <queue-json> ──▶ session
session: LLM-PICK issue → auto-api.sh prep   (select+claim → worktree+branch from develop-auto)
  → EXECUTE: consensus via host-native subagents, BOUNDED rounds,
             commit each accepted change via auto-api.sh commit (conventional, gitleaks, no co-author, build-per-commit)
  → auto-api.sh finish   (push → PR base=develop-auto, hard-locked + verified → auto-merge-when-green)
  → close issue / auto-api.sh escalate → auto-api.sh release claim
  ── report.fifo: REPORT result=<r> issue=<N> ──▶ daemon
daemon: next ROUND while work exists; else idle-poll ~15m  (or STOP <reason>)
```

---

## 2. Branching, base-lock, CI parity, auto-merge (HC1)

### 2.1 Base hard-lock — `bin/auto-pr-create.sh`
The **only** sanctioned PR-creation path. Three guards:
- **Guard 1 (pre-create):** requested base must equal `develop-auto` (constant `AUTO_BASE_BRANCH`, never overridable by any arg) — else exit `70`.
- **Guard 2 (branch origin):** head branch must derive from `origin/develop-auto` (`git merge-base --is-ancestor`) — else exit `71`.
- **Guard 3 (post-create verify):** re-read `gh pr view --json baseRefName`; if base ≠ `develop-auto`, **close the PR immediately** (`gh pr close`) — else exit `72`. This makes the lock *provable*, not assumed (defends against `gh-merge-base` config / default-branch fallback).
- **Defense-in-depth (optional):** server-side `auto-base-guard.yml` on `develop-auto` that fails any auto-authored PR whose `base_ref != develop-auto`. Added to the **parity exclusion list** (auto-infrastructure, not a CI gate).

### 2.2 CI parity — `bin/ci-parity-check.sh` (three layers, all must PASS)
Parity = *the set of REQUIRED status checks GitHub will demand on a PR→`develop-auto` equals the set for a PR→`develop`*.
- **Layer A — triggered-check-name parity.** Read each workflow **as it exists on each branch** (`git show origin/<branch>:<path>`); a per-branch file difference is itself a failure (`WORKFLOW_FILE_DIVERGENCE`). Parse YAML (`python3` `parse_wf.py`; `yq` accelerator). Simulate GitHub `on.pull_request.branches`/`branches-ignore` glob evaluation (`branch_match.py`, last-match-wins, `*`=no-slash/`**`=any) for both branches; if `triggers(develop) != triggers(develop-auto)` → `BRANCH_FILTER_DIVERGENCE`. Resolve check-run **names** (matrix Cartesian expansion, reusable `uses:` ref must be identical → `REUSABLE_REF_DIVERGENCE`, recurse in-repo). `paths`/`paths-ignore` are **parity-neutral** (filter by changed files, not base branch). Compare `NAMES(develop)` vs `NAMES(develop-auto)` → `CHECK_NAME_SET_DIVERGENCE`.
- **Layer B — required-status-check parity.** Union classic branch protection + rulesets (`gh api repos/:o/:r/branches/<b>/protection` and `.../rules/branches/<b>`) for both branches; diff → `REQUIRED_CHECK_DIVERGENCE`. Contexts produced by non-Actions apps (CodeQL SaaS, coverage bots) → `EXTERNAL_REQUIRED_CHECK` WARN, but must be present identically on both branches.
- **Layer C — required ⊆ triggered** on `develop-auto`; a required check that never runs = permanent pending → `ORPHAN_REQUIRED_CHECK`.

Exit `2` on any failure with the exact diverging element printed.

### 2.3 Auto-merge — `bin/auto-merge-when-green.sh`
- **Method: squash** (`gh pr merge --squash --subject "<PR title>" --body ""`). One issue → one small PR → one atomic conventional commit on `develop-auto` for a clean human promotion. The empty scrubbed body guarantees no `Co-Authored-By` survives the squash even if an upstream CLI injected one (HC6); additionally every per-commit message is screened by the commit gate (§4).
- **Mechanism: local poll-then-merge** (primary), not platform `--auto` (it needs branch protection and silently waits forever if a check never reports). Poll `gh pr checks --required --json bucket,state,name,workflow` (exit 8 = pending). `gh pr merge --auto` is wired only as an **optional accelerator** (`--prefer-platform-automerge`) when preflight confirms protection.
- **GREEN FLOOR (resolves the "green-on-nothing" hole):** auto-merge is **refused** unless the `develop-auto` required-check set is **non-empty** (preflight A7'; §6). On an empty required-check set the engine never merges — it labels the PR `status:blocked` and escalates so a human establishes CI. This closes the "merge unverified code on zero checks" gap.
- **Flaky budget:** `FLAKY_RETRY_MAX=2` reruns of only failed required checks (`gh run rerun --failed`); then escalate (never merge red). Pending polls until `CHECK_POLL_TIMEOUT=3600s`, then escalate.
- **Conflicts:** `gh pr update-branch` (merge-from-base, **no force**) ONLY. Force-push is forbidden on every branch (decisions.md §2); if the base cannot be merged cleanly, /auto escalates (`EX_PR_CONFLICT`).

### 2.4 Review requirement on `develop-auto` (the model-breaker)
A PR author cannot self-approve, so any `required_approving_review_count ≥ 1` on `develop-auto` makes autonomous merge impossible. Resolution priority: **(1) `develop-auto` requires ZERO reviews** (recommended; parity binds *checks*, not review count, so identical checks are preserved) → **(2)** distinct second-approver token `AUTO_APPROVER_TOKEN` (a *different* account from the PR author) → **(3) reject** `--admin` bypass. Preflight A6 aborts if reviews≥1 with no second approver. This intersects the two-account reality (§6.4).

---

## 3. Serial loop, claim protocol, kill-switch (HC7)

### 3.1 One-issue-at-a-time loop
The loop works **exactly ONE issue at a time** — select+claim, take it through to PR, release, then move on. (Subagent fan-out *within* an issue is separate and always flat/depth-1.) There is **no** in-process parallelism and no concurrency ceiling. The **per-issue claim/lease** is the single mutual-exclusion mechanism: it is what prevents two daemon instances (running on different clones) from double-working the same issue — the loser of the claim re-read + tie-break exits cleanly.

### 3.2 CAS-free claim — `bin/auto-claim.sh <issue#>`
GitHub has no compare-and-swap on issue mutations, so:
- All writes are **additive** (`gh issue edit --add-label/--add-assignee`, append-only `gh issue comment`) → a loser never destroys the winner's lease.
- **Lease comment** (HTML-comment marker line with `runner=`, `ttl_seconds=`, `kind=claim|renew|reclaim|release`) is authoritative; the label `auto:claimed` is a cheap pre-filter; assignee is cosmetic.
- **Win by re-read + deterministic tie-break:** after a 1–3s jitter, re-read the comment set; among **live** leases (server `createdAt + ttl > now`): a `kind=reclaim` (newest) supersedes; else **oldest `createdAt`** wins (ties by lexicographic `runnerId`). Loser self-retracts. An expired/revived dead runner is never in the live set → cannot win → must re-claim.
- **Stale reclaim** (`bin/auto-stale.sh`): newest live lease older than `AUTO_LEASE_TTL` (default 30m, heartbeat at TTL/2) AND **no open PR for the issue** AND issue still OPEN/not-blocked.
- **Idempotent PR creation:** before `gh pr create`, check both `gh pr list --base develop-auto --head <branch>` (exact head match, strongly consistent via refs) **and** the `Closes #N` search (eventually-consistent, best-effort). The **head-branch existence check is authoritative** (the search is advisory) — this strengthens the racy `Closes #N`-only approach the lenses used.

### 3.3 Release & escalation — `bin/auto-release.sh <issue#> <reason>` (always via shell `trap EXIT INT TERM`)
- **Success (PR opened):** lease `kind=done-pr` + PR URL; issue keeps `status:in-progress`/moves to `status:in-review`; not re-queued.
- **Recoverable failure:** remove claim labels, restore `auto:eligible`, lease `kind=release`.
- **Hard failure / rounds exhausted (HC4):** `status:blocked` + escalation issue (see §3.4).

### 3.4 Escalation policy (resolves the three-lens label contradiction)
**Authoritative:** escalation/follow-up issues are filed **human-gated** with `auto:hold` + `status:triage` + `type:*` — **NOT** auto-eligible. They do **not** re-enter the autonomous queue automatically. The original issue is marked `status:blocked` + `blocked`, its PR left as **draft** (never merged). This prevents the unbounded escalation→fail→escalation chain. Additionally an `escalations` counter in state + a `--max-escalations` ceiling hard-stops the run if escalations spike. *(The `auto:queued`/`auto:followup` re-eligible variants from other lenses are rejected.)*

### 3.5 Kill-switch (single canonical contract — resolves the 3-vs-2-vs-1 inconsistency)
A single function `bin/auto-kill.sh` (cached 20s/process), checked at **five points** (iteration top; just after claim; each subagent/phase boundary; before commit/push; before PR open). Killed if **either**:
1. **PRIMARY** — label `auto:stop` present on the pinned **control issue** `#auto-control` (one tap on GitHub mobile, or `gh issue edit <ctrl#> --add-label auto:stop`).
2. **FALLBACK** — file `.auto/STOP` exists **on the `develop-auto` branch**, read remotely via `gh api repos/:o/:r/contents/.auto/STOP?ref=develop-auto` (so local ignore is irrelevant).

The repo-variable `AUTO_KILL` source (poor mobile UX, needs Actions scope) and title-convention source are **dropped**. Kill is cooperative: the current atomic commit finishes (buildable-per-commit), then the iteration releases its claim and exits. Resume = remove `auto:stop` / delete `.auto/STOP`; the daemon's next poll tick auto-resumes.

### 3.6 Control-issue lifecycle (resolves per-run vs repo-global ambiguity)
`#auto-control` is a **single repo-global, permanent** pinned issue created once by preflight (idempotent: locate-or-create). The `auto:stop` label lives on it and is **repo-global** — it halts whatever run is active and any future run until removed. The **per-run status dashboard** is a *separate* issue (`auto:status`, titled with `run_id`), updated each iteration, unpinned on terminal state. So: one permanent control/kill issue + one per-run status issue. A new `/auto` invocation that finds `auto:stop` still set on `#auto-control` aborts at gate point 1 with a clear message (this is intended — a human kill persists across runs).

---

## 4. Commit & branch rules + enforcement (HC6)

- **Branch:** `auto/<type>/<issue#>-<slug>` (`<type>`∈{feat,fix,chore,spike,docs,test,perf,refactor}; slug ≤40 chars), always cut from `origin/develop-auto`.
- **`bin/commit-gate.sh`** runs on **every** commit and is enforced (not advisory) because the engine routes **all** commits through it (the engine never calls raw `git commit`; it calls a wrapper that invokes the gate first):
  1. **Reject** any `Co-Authored-By:` line (HC6 / user rule) — closes the co-author-leak path that several agent CLIs introduce by default.
  2. **Reject** non-conventional subject (regex on `type(scope)!: subject`).
  3. **gitleaks** `protect --staged --redact` → reject on hit. **Hard, not WARN:** preflight A10 asserts `gitleaks` is installed and **aborts the run** if absent (closes the "silent no-op on hosts without gitleaks" gap). The `review-secrets-leaks` subagent is a **second, independent** scan (manual review + gitleaks at a different granularity); the two are deliberately complementary, not duplicative.
  4. **Buildable-per-commit enforcement (closes the unenforced-policy gap):** before finalizing a commit, run the project's **fast build/test gate** (`bin/build-check.sh`, auto-detected: `npm run build`/`test`, `pytest -x -q`, `go build ./...`, `make check`, etc.; configurable in `.github/auto/auto.config.json`). If the staged tree fails the fast gate, the commit is rejected and the engine must fix-forward before committing. The full CI on the PR remains the authoritative gate; this catches broken intermediate commits early.

---

## 5. Engine: the consensus protocol + write-access enforcement (HC4)

### 5.1 The consensus protocol (every issue)
`/auto` makes its two real cognitive decisions — **what to build** and **is it done** — by
biased, independent **subagent consensus** (borrowed from consensus-rnd's `sshx`), never by
a single agent. The SAME protocol runs for every issue; `size:*` is **informational only**,
not an engine selector. All roles are **subagents only**, flat / depth-1; each TRIPLET is
spawned **in parallel** so its three members are **isolated** — a member sees only its
dispatch brief (the `GoalArtifact` + repo/diff), never its peers' output (No Context
Pollution). The session carries back only each member's compact `conclusion`; full reasoning
stays in the member's own transcript.

1. **intake** — the session builds the `GoalArtifact`: normalized_goal, constraints,
   `success_criteria` (= the issue's acceptance criteria; the fixed target), iteration_question.
2. **DESIGN consensus** — thinking triplet `solver-minimal` / `solver-structural` /
   `solver-delete` (each → propose/revise/reject/abstain + plan) → `meta-judge` (design
   truth table) → ONE concrete plan, or `escalate`. The approved plan is the only thing built.
3. **implement** — `implement-backend` / `implement-frontend` builds ONLY the approved plan;
   `debug` only if the build/tests go red. Every commit goes through `commit-gate.sh` (§4).
4. **REVIEW consensus** — review triplet `reviewer-requirements` / `reviewer-quality` /
   `reviewer-tests` (each → approve/comment/reject) → `meta-judge` (review truth table) →
   `done` or `fix`. `review-secrets-leaks` runs as a standing hard gate alongside.
5. **fix loop** — on `fix`, the implementer closes the meta-judge's blocking items, commits,
   and the REVIEW consensus re-runs; bounded by `AUTO_ROUNDS_CEILING` (5), then escalate.

### 5.2 The two truth tables (meta-judge; fixed)
- **Design:** unanimous actionable plan → `implement`; close disagreement w/ compatible plans
  → `converge` (produce ONE concrete plan); bounded true stall → `escalate` with options; one
  perspective treated as the whole → `reject-fake-consensus`.
- **Review:** any explicit reject → `fix`; no reject + ≥1 approve → `done` (advisories
  surfaced); all comment → another bounded pass or ask. **Requirements conformance is
  MANDATORY**: if `reviewer-requirements` is not `approve` (the diff does not provably meet
  100% of `success_criteria`), the exit is `fix` regardless — /auto's "100% meets requirements"
  gate. Each agent owns its bias prompt in `agents/<role>.md`.

### 5.3 Write-access enforcement (honors user critical-rules)
Each role's tool grant lives in its native subagent file `agents/<role>.md` `tools:` frontmatter — applied automatically by the host agent when the session spawns the role via the host's native subagent mechanism (the session passes no tool string):
- **Write-capable** (`implement-backend`, `implement-frontend`, `write-documentation`): `Read, Edit, Write, Bash, Grep, Glob`.
- **Read-only** (the design solvers, the meta-judge, the review triplet, debug, secrets-leaks): `Read, Grep, Glob` — no Edit/Write/Bash, so they **physically cannot mutate the repo or run commands**. They emit findings on stdout (their returned summary); the session feeds them the scoped diff. Persistence is delegated to `write-documentation`.

`lib/roles.sh` keeps the same write/read-only classification as the single source of truth that the agent files mirror. This makes the user's write-access rule **enforced by the subagent definitions**, not merely verbal.

### 5.4 Bounded fix loop → escalate (HC4)
The REVIEW-consensus `fix` loop is bounded by `AUTO_ROUNDS_CEILING` (5). Success = the
review meta-judge exits `done` (no reject, requirements approved) AND CI 100% green →
auto-merge eligible. A design-consensus `escalate`, or fix-loop exhaustion with a `reject`
still open, → human-gated escalation per §3.4 (idempotent `auto-release.sh --outcome hard`:
`auto:hold` + `status:triage` follow-up, original `status:blocked`, PR left draft, move on).

---

## 6. Preflight (HC3) — `bin/auto-preflight.sh`
Abort-on-fail; each failure prints the **exact** unmet condition and exits non-zero. Emits one machine-readable line per assertion (`PASS A3 ...` / `ABORT A6 ...`).

- **A1** origin remote exists and is GitHub.
- **A2** `gh auth status` logged in; token scopes include `repo`+`workflow`.
- **A3** BOTH `develop` and `develop-auto` exist **on origin** (`git ls-remote --heads`). **Never auto-create `develop-auto`**; print "create it from develop and re-run."
- **A4** YAML parse capability present (`yq` OR PyYAML OR vendored `miniyaml.py`).
- **A5** CI parity (`ci-parity-check.sh`) PASS; surface the failing item.
- **A6** branch-protection compat on `develop-auto`: review-count ≥1 with no `AUTO_APPROVER_TOKEN` → ABORT with remediation.
- **A7** if `develop` has required checks, `develop-auto` must too (no disabled-gate bypass).
- **A7'** GREEN FLOOR: `develop-auto` required-check set must be **non-empty**, else ABORT "auto-merge would ship unverified code (empty required-check set); establish at least one required status check on develop-auto."
- **A8** WARN (not abort) if auto token has admin that could bypass checks; record `--admin` is never used.
- **A9** `allow_squash_merge` is true on repo (we squash).
- **A10** `gitleaks` installed → else ABORT (commit gate would silently skip secret scan).
- **A11** account selection deterministic: after the daemon's single start-of-run `gh auth switch --user <account>`, the resolved gh login is snapshotted and `AUTO_GH_ACCOUNT` asserted to match (§6.4); if a second-approver flow is configured, the approver account ≠ author account.
- **A12** kill-switch not currently set (`auto:stop` absent on `#auto-control`, `.auto/STOP` absent on `develop-auto`) — else abort with "kill-switch is engaged; clear it to start."

### 6.4 Account selection (operator-supplied; one switch at start)
The operator passes the target account as the `<gh-account>` argument to `/sa-implement`. The **daemon performs exactly ONE `gh auth switch --user <account>` at start** — the operator passing the account argument **IS the authorization to switch**. After that switch the engine behaves as before: it resolves the now-active login (`gh api user`), snapshots it to `.auto/.account`, and every mutation boundary re-asserts it and **hard-refuses any later mid-run drift** (`EX_PREFLIGHT_ACCOUNT=69`). Beyond the single start-of-run switch, the engine never mutates machine-global gh/git state mid-run. `AUTO_GH_ACCOUNT` remains meaningful as the resolved/expected account: once the switch has happened it is the snapshotted run account, and preflight asserts the active login matches and aborts otherwise. Roles stay distinct: **claim-lock account** = author account = the resolved run account; **approver account** (only if `develop-auto` requires reviews) = a *different* account via `AUTO_APPROVER_TOKEN`. Commit identity = the user's git config, with a GitHub-noreply fallback derived from the login only when git has no identity configured. Tokens are **env/keychain only**, never committed; `.gitignore` covers `.env`, `.env.*`, `*.pem`, `*.key`, `credentials.json`, and `gitleaks` is configured with a rule to catch `gho_`/`ghp_`/`github_pat_` tokens.

---

## 7. State, continuity, context limits (HC5, HC7)

### 7.1 State location (resolves committed-to-develop-auto vs disposable-local contradiction)
**Authoritative: durable state is GitHub (issues/labels/PR/comments); local `.auto/` is disposable cache and is NEVER committed to any branch.** This honors HC7 ("local context is disposable") and avoids polluting/`force`-pushing `develop-auto` outside the PR flow. The previously-proposed "commit `state.json`+logs to `develop-auto`" approach is **rejected**. The **only** thing that ever lives on `develop-auto` outside a PR is the optional `.auto/STOP` kill sentinel (a deliberate human-flippable signal, read remotely; not written by the engine). Resume after crash is rebuilt **entirely from GitHub**: open PRs by head branch, issue labels (`status:in-progress`), and the live machine-parseable **lease comment** on the work issue. Local `.auto/state/run-<id>.json` is a convenience cache only and is reconstructed from GitHub if missing.

### 7.2 Cold-start safety
Top of every iteration re-derives 100% of the working set from `gh` queries + the work issue's lease comment; nothing relies on carried agent context. `status:in-progress` label + open PR + lease comment are the redundant in-flight markers. `kill -9` between any two steps leaves a resumable state; commit-early/push-early means at most one un-pushed phase is redone.

### 7.3 Daemon-driven continuity
- **Single continuity mechanism** — the bash daemon `bin/auto-daemon.sh` owns the loop's cadence. While work exists it is **report-driven**: it pushes a `ROUND <n> <queue-json>` over `work.fifo`, then **blocks awaiting the session's `REPORT`** over `report.fifo` before pushing the next round. When the queue is empty it **idle-polls every ~15 minutes** until work reappears (or a `STOP <reason>` condition fires).
- **Triggering the session:** the daemon does not pick issues; it surfaces the prioritized candidate queue in the round payload and the agent session LLM-picks. The daemon resurrects the loop deterministically after any session exit/crash — the next round simply re-derives the working set cold from GitHub.
- **Hand-off without double-fire:** the **per-issue claim is the single mutual-exclusion mechanism** (no separate channel). Any concurrent daemon/session instance runs the identical claim protocol; the loser exits cleanly. (We do **not** introduce a second global git-CAS lease — the additive-comment per-issue lease is the one model.)

### 7.4 Context management (native)
Each role **subagent** runs in its own context window, so heavy analysis/implementation is isolated off the session — the session keeps only the small per-round summaries the subagents return. If the session itself nears its window during a long iteration, the next daemon `ROUND` resumes the SAME issue cold from GitHub + the worktree (existing commits / open PR). There is no shell-level context-budget guard or re-arm sentinel any more — that was only needed to babysit headless `claude -p` workers.

### 7.5 Logging (user logging rule)
Append-only NDJSON journal in **local** `.auto/log/YYYY-MM-DD.ndjson` (disposable; never committed) at INFO (lifecycle), DEBUG (flow, gated by `--verbose`), ERROR (failures with `issue`/`phase`/`cause`). ERROR events also drop a comment on the per-run status issue for visibility. The agent never reads the journal back into context.

### 7.6 Continuity (daemon)
Continuity is the bash daemon `bin/auto-daemon.sh` alone — a deterministic, long-running process that owns the loop's cadence (report-driven while work exists; ~15-minute idle-poll when the queue is empty), switches `gh` to the operator-supplied account once at start, runs preflight, polls the issue queue, and triggers the agent session over the `work.fifo`/`report.fifo` pair under `.auto/daemon/`. There is **no** in-session `/loop` and **no** out-of-session cron/`/schedule` routine — the daemon is the single continuity mechanism, and the per-issue lease is the single mutual-exclusion mechanism (any concurrent instance's loser exits cleanly). The engine verbs behind `bin/auto-api.sh` (`prep`/`finish`/…) remain pure `git`+`gh` and could in principle be driven by another scheduler, but the daemon is the supported path.

---

## 8. Stop conditions & arg semantics (HC8)
The stop conditions are `--duration`/`--until`, `--max-prs`, and `--max-escalations`, plus the kill-switch. Theme selection is `--theme/--label`. There is **no cost ceiling**: `--max-cost`/`--max-tokens` are accepted as reserved no-op flag names (so usage strings don't break) but do nothing — token accounting belonged to the old headless-adapter path. If the user asks for a cost ceiling, offer `--max-prs`/`--duration` instead.

---

## 10. Single-root `.gitignore` (user critical-rule)
**Exactly one** `.gitignore` at repo root. Because `.auto/` is now **never committed** (§7.1), the contradiction is gone: the root `.gitignore` simply ignores **all** of `.auto/`. It also ignores all secret-bearing files. Content:
```
# /auto disposable runtime cache (never committed; durable state lives in GitHub)
.auto/
# secrets / credentials (user critical-rule)
.env
.env.*
*.pem
*.key
*.p12
credentials.json
*.token
# OS / editor noise
.DS_Store
```
The `.auto/STOP` kill sentinel, when used, is created **on the `develop-auto` branch by a human** (or by an explicit operator action) and read remotely; the engine never stages it, so the blanket `.auto/` ignore in working trees is correct and consistent.

---

## 11. Distribution — host-neutral skill package (HC2)
`/sa-implement` ships as ONE host-neutral **skill package** — a plain directory, not a plugin and with no marketplace:

- **Layout:** a single package directory containing `SKILL.md` + `bin/` + `lib/` + `agents/` + `references/` + `templates/`. There is no `.claude-plugin/marketplace.json`, no `plugins/auto/` nesting, and no per-host registration step.
- **Install:** drop the package directory in place (or clone the repo) and set `AUTO_HOME` to the package's own base directory per the SKILL.md instructions. This makes BOTH skills (`/sa-design`, `/sa-implement`), all role subagents, the bash daemon, and the `bin/`+`lib/` engine available together — one bundle, one update.
- **Invocation:** **`/sa-implement <repo-url> <gh-account>`** (two args) and **`/sa-design`**. The agent session spawns role workers via the **host's native subagent mechanism** (OpenCode, Codex, or Claude Code). *(A fallback for hosts without native subagents — the daemon spawning extra agent processes to vote in consensus — is **to be wired later**.)*
- **Runtime paths:** `AUTO_HOME` resolves to the package base directory; SKILL.md uses `${AUTO_HOME}/bin` + `/lib` to call the engine (replacing the old `readlink` self-location and the former `${CLAUDE_PLUGIN_ROOT}`).
- **No adapter, no `--agent`, no headless `claude -p`.** Role workers are host-native subagents; the agent session is the cognitive worker, the bash daemon owns cadence, and all mutations go through `bin/auto-api.sh`. (The previous four-capability `define-skill`/`spawn-subagent`/`headless-invoke`/`re-arm` adapter contract existed only to drive *other* CLIs and has been removed.)

---

## 12. Skill package layout
```
sa-implement/                          # the skill package (= AUTO_HOME)
├── SKILL.md                           # /sa-implement <repo-url> <gh-account> — the implement-loop entry
├── agents/<role>.md                   # the 12 host-native role subagents
├── bin/
│   ├── auto-daemon.sh                 # the bash daemon (owns cadence/triggering; work.fifo/report.fifo)
│   ├── auto-api.sh                    # the verb layer (queue/prep/commit/finish/escalate/release/kill-check/status)
│   └── …                              # the rest of the deterministic git+gh engine
├── lib/                               # shared shell helpers (roles.sh, etc.)
├── templates/.github/                 # issue forms (feature/bug/chore), PR template, labels, auto-base-guard
└── references/                        # this design doc + conventions + state-model
```
(The companion `/sa-design` skill ships alongside as its own package directory.) No `adapters/` and no `.claude-plugin/` (removed). The deterministic engine (`bin/`+`lib/`) is unchanged by packaging — it is plain `git`+`gh` shell, reached only through `bin/auto-api.sh`, and the bash daemon drives it.

---

## 13. Resolved contradictions (summary)
| Conflict | Resolution |
|---|---|
| Concurrency | **Single issue at a time; per-issue lease** (the lease prevents two daemon instances on different clones from double-working one issue; subagents always flat within an issue). |
| Label taxonomy (3 namespaces) | **One canonical taxonomy** (§ labels.json): `priority:*`, `type:*`, `size:*`, `status:*`, `auto:{eligible,claimed,hold,stop,status}`, flat `blocked`. All other lens variants dropped. |
| Escalation re-queue | **Human-gated** (`auto:hold`+`status:triage`), never auto-eligible; `--max-escalations` ceiling. |
| Claim mechanism | **Additive lease-comment + deterministic tie-break** (one model); git-CAS-on-state.json rejected. |
| State location | **GitHub durable; `.auto/` disposable, never committed.** |
| Force-push | **Forbidden everywhere; `gh pr update-branch` (no force) is the only conflict path.** |
| Review-round bounds | **Per-size table authoritative** (S=1,M=2,L/XL=3, ceiling 5). |
| Kill-switch sources | **`auto:stop` label on `#auto-control` + `.auto/STOP` on develop-auto**; repo-variable/title dropped. |
| gitleaks presence | **Hard preflight A10 + enforced commit gate**, plus independent `review-secrets-leaks` subagent. |
| Co-author leak via squash | **Empty scrubbed squash body + commit-gate reject of `Co-Authored-By` on every commit.** |
| Green-on-nothing | **GREEN FLOOR (A7'): non-empty required-check set required for any auto-merge.** |
| Two accounts | **Deterministic: daemon does ONE `gh auth switch` to the operator-supplied account at start, snapshots it (`AUTO_GH_ACCOUNT` asserted), refuses drift; approver ≠ author when reviews required.** |

Items that **must be confirmed by the user before build** are in `openQuestionsForUser`.

