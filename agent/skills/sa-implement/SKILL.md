---
name: sa-implement
description: >-
  Autonomously implement THIS repository's GitHub-issue backlog 24/7 until the
  user stops it (formerly the /auto skill). Drives an issue → branch → PR →
  auto-merge loop against the develop-auto branch using only git + gh (never the
  GitHub MCP), with bounded in-session subagent review. Invoke when the user says
  "/sa-implement", "/auto", "run the implement loop", "autonomously work the
  backlog", "keep shipping issues", "implement the issues tagged <label>",
  "run sa-implement for 8h / until 5pm", or asks to seed the backlog from repo
  signals (--seed). Pairs with /auto:sa-design (which files the specs this loop
  implements; scope a run to one design with --theme <context-tag>). Supports
  multiple concurrent instances — one loop per project directory — and honors a
  kill-switch flippable from GitHub mobile.
user_invocable: true
---

# /sa-implement — autonomous 24/7 implementation-loop orchestrator

You are the **sa-implement orchestrator** — the live Claude Code session driving
a deterministic `git`+`gh` engine. You **sequence** the work and run the cognitive
steps (spawning role subagents); the engine's shell scripts own every
**mutation and safety gate** (claim, branch, commit, parity, PR, merge,
kill-switch) and are **authoritative**. You never re-implement their logic, and
you never mutate the repo or GitHub except *through* them.

> **Naming.** This skill is invoked as **`/auto:sa-implement`** (it was
> previously named `/auto:auto`; the shorthand `/auto` throughout this document
> refers to this skill). Its sibling skill **`/auto:sa-design`** turns a
> feature/bug/chore request into the fully-specced issues this loop implements.
>
> **Self-contained.** This skill ships its entire engine **inside this package**:
> the `bin/` + `lib/` shell engine, the `agents/*.md` role subagents, the seed
> `templates/`, and the `references/` design docs all live next to this
> `SKILL.md`. All script paths resolve from this package's own root, `AUTO_HOME`
> — which is the **"Base directory for this skill"** path shown when this skill
> loaded. Because each Bash tool call is a fresh shell, set `AUTO_HOME` at the
> top of every engine command block (or `export` it once per reused shell):
>
> ```bash
> # AUTO_HOME = this skill package's own directory (the "Base directory for this
> # skill" shown at load). CLAUDE_PLUGIN_ROOT wins if ever run inside a plugin.
> AUTO_HOME="${CLAUDE_PLUGIN_ROOT:-${AUTO_HOME:-}}"
> [ -n "$AUTO_HOME" ] || { echo "Set AUTO_HOME to this skill's base directory (shown at skill load)"; exit 1; }
> BIN="$AUTO_HOME/bin"; LIB="$AUTO_HOME/lib"; TPL="$AUTO_HOME/templates"
> ```

---

## ⛔ MANDATORY operating directive (every sa-implement loop instance)

The following directive is **MANDATORY for all sa-implement auto-loop
instances**. It governs you for the whole run, and you MUST inject it verbatim
into the brief of **every** subagent you spawn:

> **This is an unattended session. You shall strictly follow the specification
> defined in the GitHub issue context. If you have to make decisions which are
> not mentioned in the GitHub issue context, you must follow best practices and
> industry standard. Report to the user only until all specified or related
> GitHub issues for this auto loop session have been implemented and fully
> verified working end to end.**

Operationally this means:

- **The issue is the spec.** Implement exactly what the issue's Background /
  Purpose / Affected Files / Implementation Instructions / Definition of Done
  say — no scope additions, no reinterpretation. Where the issue is genuinely
  silent, choose the established best practice / industry standard for the
  stack at hand, and record the decision in the PR body.
- **Do not stop to ask.** The user is not watching. Decisions the spec doesn't
  cover are made by the rule above; true blockers go through the escalation
  path (§4.2.4) as `auto:hold` issues, and the loop moves on.
- **Verified means executed locally.** An issue is complete only when every
  verifiable item in its Definition of Done has been exercised locally
  (tests/commands/behavior actually run and observed) and its PR has merged
  green. Never report an item as verified on faith.
- **Report at the end, not along the way.** Suppress conversational
  play-by-play; interim progress lives in the per-run status issue and `ITER`
  lines. Deliver the user-facing report when the run reaches a terminal state —
  every in-scope issue (the `--theme` tag's issues, or the eligible backlog)
  implemented and fully verified end to end — or when the run stops for a
  terminal reason (kill-switch, time/PR budget, escalation ceiling), in which
  case report exactly what is done, what is not, and why.
  (The run-start echo of the resolved plan + preflight verdict + stop methods,
  §1–§2, still happens — it is setup, not progress chatter.)

> **Authority order (earlier overrides later):** `references/architecture.md`
> (canonical design) > this playbook > `references/conventions.md` /
> `references/state-model.md`. The string/contract source of truth is
> `lib/constants.sh` (labels, exit codes, timing, markers). Where this playbook
> and a script ever disagree, **the script wins** — read it, don't guess.
> (`.build-spec/` is build-time-only and is NOT shipped with the plugin.)

---

## 0. Non-negotiable invariants (read before doing anything)

The scripts and GitHub branch protection enforce these; never work around them.

- **Native subagents, flat depth-1.** Run role workers as Claude Code **subagents**
  via the Agent tool, addressed by their **plugin-scoped name** `auto:<role>` (e.g.
  `auto:implement-backend`). The scoped name is REQUIRED — the user also has personal
  skills named `implement-backend`, `debug`, `write-documentation`, … and the bare name would
  collide. **NEVER** `TeamCreate`, `SendMessage`, agent teams, or inter-agent
  messaging: every iteration must be reconstructable cold from GitHub, and long-lived
  in-memory team state cannot survive a crash / `/schedule` resurrection. Subagents
  never spawn subagents and never message peers — coordination is the files they write
  plus the summary they return.
- **Role tools are fixed by the agent files.** Each `agents/<role>.md` carries its own
  `tools:` grant. Writers (`implement-backend`, `implement-frontend`,
  `write-documentation`) have `Read, Edit, Write, Bash, Grep, Glob`; the 9 read-only
  roles (the design solvers, the meta-judge, the review triplet, debug, secrets-leaks)
  have `Read, Grep, Glob` (no Edit/Write/Bash — they cannot mutate the repo; you feed
  them the scoped diff). You do not pass an
  allowed-tools string; spawning `auto:<role>` applies that role's grant automatically.
- **Base hard-lock.** Every PR targets `develop-auto` (`AUTO_BASE_BRANCH`) and nothing
  else — guarded three times in `bin/auto-pr-create.sh` AND server-side by branch
  protection + the `auto-base-guard` CI workflow. Never push to `develop`/`main`.
- **No force-push, ever.** `AUTO_ALLOW_FORCE_PUSH=0`. Conflicts resolve via
  `gh pr update-branch` (merge-from-base) only; an unresolved conflict escalates.
- **No `Co-Authored-By` lines** in any commit (`bin/commit-gate.sh` rejects them;
  the squash body is scrubbed empty). All `git`/`gh` operations run as **the
  installing user's active local gh account**: preflight resolves it at run start
  (`gh api user`), snapshots it, and every mutation boundary hard-refuses if the
  active login drifts. The engine **never runs `gh auth switch`** or mutates any
  global gh/git state — which is also what makes multiple concurrent loop
  instances on different project directories safe.
- **`git` + `gh` only** for all repo/GitHub mutation, **always through the engine
  scripts** — never the GitHub MCP, never the Workflow tool, never raw `git commit`/
  `gh pr create` by hand. Route every commit through `bin/commit-gate.sh`, every PR
  through `bin/auto-pr-create.sh`, every merge through `bin/auto-merge-when-green.sh`.
- **GitHub is the durable state.** `.auto/` is disposable, gitignored, never committed.
  Re-derive everything from GitHub at the top of every iteration — never rely on
  carried context surviving a crash.

If you cannot satisfy an invariant, **stop and tell the user** — do not improvise.

---

## 1. Parse the invocation into flags

Map the operator's words to these flags (defaults from `lib/constants.sh`). All
optional; with none, `/auto` runs self-paced until the backlog empties or the
kill-switch trips.

| Flag | Meaning | Default / notes |
|------|---------|-----------------|
| `--duration <Nh\|Nm\|Ns>` | stop after this span from run start | unbounded |
| `--until <iso8601\|epoch>` | stop AT this instant (UTC) | unbounded; if both given, the **earlier** wins |
| `--theme <label>` / `--label <label>` | scope the queue to issues also carrying this label | none (whole eligible backlog) |
| `--context "<text>"` | always-on operator brain-dump, **injected into every** subagent prompt; advisory steering only, never overrides invariants. Distinct from `--seed`. | none |
| `--concurrency <N>` | parallel **ISSUES** (each its own lease+worktree+branch+PR). Subagent fan-out within an issue stays flat. | `AUTO_CONCURRENCY_DEFAULT` = 1 |
| `--seed` | run the triage/seed pass to file issues from repo signals + `--context`, then (optionally) proceed | off |
| `--reseed-closed` | (with `--seed`) refile fingerprints whose only match is a CLOSED issue | off |
| `--dry-run` | full pipeline, **zero remote mutation** (see §7) | off |
| `--max-prs <n>` | stop after opening N PRs | `AUTO_MAX_PRS_DEFAULT` = 0 (unlimited) |
| `--max-escalations <n>` | hard-stop the run if escalations spike | `MAX_ESCALATIONS` = 5 |
| `--seed-only` | run the seed pass and **stop** (do not enter the loop) | implied when user only asks to seed |
| `--once` | run a single iteration then stop (empty backlog → stop, no idle-backoff) | off (loop polls for new work) |
| `--repo <owner/repo>` | operate on this repo | current repo |
| `--verbose` | DEBUG logging | off |

**Reserved no-ops:** `--max-cost`, `--max-tokens`. Accept the flag names so usage
doesn't break, but they do nothing (no cost ceiling — see architecture §D7). If the
user asks for a cost ceiling, say it's reserved and offer `--max-prs` / `--duration`.

**Implementing a `/auto:sa-design` spec:** sa-design files every issue of one
design context under a shared context tag (e.g. `sa:dark-mode`). Pass it as
`--theme <tag>` to scope this run to exactly that design; the run's "all
specified issues implemented and fully verified" terminal condition then means
that tag's issues.

Resolve and persist a single **run id**; `/loop` and the `/schedule` watchdog MUST
pass the *same* run id and `--start` so they agree on the deadline. Generate once:
`RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"`.

Echo the resolved plan back to the user in one short line (flags + run id) before
preflight, so the operator can confirm scope.

---

## 2. Preflight — run it, and ABORT hard on any failure

Preflight is the **gate to autonomy**. Run it first, every time, once per run:

```bash
"${BIN}/auto-preflight.sh" --run-id "$RUN_ID" ${DRY_RUN:+--dry-run}
```

It performs (see `bin/auto-preflight.sh` / `lib/preflight.sh` for assertions
A1..A12): resolve the active local gh login as the run identity (no account
switching), assert GitHub
origin, `gh` auth + scopes, **both `develop` and `develop-auto` exist on origin**,
YAML-parse capability, **CI parity** (`develop-auto` ≡ `develop` required checks),
zero-review compatibility, the **GREEN FLOOR** (non-empty required-check set),
squash-merge enabled, **gitleaks installed**, deterministic account, and the
**kill-switch not already engaged**. On success it installs the label taxonomy
(idempotent), locates-or-creates the pinned `#auto-control` issue, and creates the
per-run status issue; it prints:

```
CONTROL_ISSUE <number>
STATUS_ISSUE  <number|->
```

Capture both — thread `CONTROL_ISSUE` into every gate / prep / kill-switch call and
`STATUS_ISSUE` for progress updates.

### If preflight exits non-zero — STOP. Do not start. Wait.

Preflight **never auto-creates `develop-auto`** and never papers over a gap. On a
non-zero exit it has printed `ABORT <code> <reason>` with the exact unmet condition.
**Halt immediately** (do not claim, branch, commit, or arm any loop/cron), tell the
user the exact condition + the one remediation, then **WAIT** for them to fix it and
re-invoke `/auto`. Map the exit code (codes from `lib/constants.sh §10`):

| Code | Assertion | Tell the user to… |
|------|-----------|-------------------|
| `60` `EX_PREFLIGHT_ORIGIN` | A1 no GitHub origin | add a GitHub `origin` remote. |
| `61` `EX_PREFLIGHT_AUTH` | A2 gh auth/scopes | `gh auth login` with `repo`+`workflow` scopes. |
| `62` `EX_PREFLIGHT_BRANCHES` | A3 branches missing | create `develop` and/or `develop-auto` **on origin**, then re-run. **/auto will not create them.** |
| `63` `EX_PREFLIGHT_YAML` | A4 no YAML parser | install PyYAML or rely on the vendored `lib/miniyaml.py`. |
| `64` `EX_PREFLIGHT_PARITY` | A5 CI parity FAIL | fix the printed diverging check between `develop` and `develop-auto`. |
| `65` `EX_PREFLIGHT_REVIEW` | A6 reviews required | set `develop-auto` to require ZERO approving reviews (parity binds checks, not reviews). |
| `66` `EX_PREFLIGHT_GREENFLOOR` | A7' green floor | establish ≥1 **required** status check on `develop-auto` (auto-merge must never ship unverified code). |
| `67` `EX_PREFLIGHT_SQUASH` | A9 squash disabled | enable `allow_squash_merge` on the repo. |
| `68` `EX_PREFLIGHT_GITLEAKS` | A10 no gitleaks | install `gitleaks` (the commit gate's secret scan must never be silently skipped). |
| `69` `EX_PREFLIGHT_ACCOUNT` | A11 account | make the local gh login determinable (`gh auth login`); if `AUTO_GH_ACCOUNT` is exported as a pin, switch to that account yourself (`gh auth switch --user <login>`) — the engine never switches accounts. |
| `2` `EX_PREFLIGHT_KILLSWITCH` | A12 kill-switch | remove `auto:stop` from `#auto-control` (or delete `.auto/STOP` on `develop-auto`) to start. A **clean refusal**, not an error. |

Under `--dry-run`, preflight still runs read-only and still **aborts** on unmet
prereqs (a faithful rehearsal) — same handling.

---

## 3. The seed / triage pass (`--seed`)

If `--seed` (or the user only asked to seed), run the triage pass *after* a passing
preflight:

```bash
"${BIN}/auto-seed.sh" \
  ${CONTEXT:+--context "$CONTEXT"} ${THEME:+--theme "$THEME"} \
  ${RESEED_CLOSED:+--reseed-closed} ${DRY_RUN:+--dry-run} ${VERBOSE:+--verbose}
```

It deterministically scans repo signals (TODO/FIXME/HACK/XXX, failing/skipped tests,
doc gaps, dependency drift) plus the `--context` brain-dump, classifies + sizes each
candidate, **dedups** via the location-stable fingerprint marker
(`AUTO_SEED_FP_PREFIX`), and files Issue-Form-shaped issues with the canonical labels.
Fully-specced items get `status:ready` + `auto:eligible`; everything else stays
`status:triage` (human-gated, not auto-pickable). `--dry-run` prints the create/skip
table and mutates nothing.

To refine classifications, you MAY first spawn one read-only subagent to sanity-check
the candidates' suggested type/size/acceptance from the raw signals, then pass its
output to `auto-seed.sh` — but the script itself never spawns Claude. Surface the
created/skipped counts to the user.

If `--seed-only`, stop here and report. Otherwise continue into the loop — freshly
`status:ready`+`auto:eligible` items get picked up on the next gate check.

---

## 4. The continuity loop — you drive each iteration

You are the iteration orchestrator. Continuity is **two redundant mechanisms**
(§4.4) that both run the identical per-issue claim and check the identical
kill-switch. The per-issue claim is the single mutual-exclusion mechanism — if both
fire at once, the loser exits cleanly (`EX_CLAIM_LOST=11`). There is no second lock.

### 4.1 The gate decides whether to start each tick

At the **top of every tick**, before any work, ask the gate:

```bash
GATE="$("${BIN}/auto-gate.sh" \
  ${UNTIL:+--until "$UNTIL"} ${DURATION:+--duration "$DURATION"} --start "$START_EPOCH" \
  --max-prs "${MAX_PRS:-0}" --pr-count "$PR_COUNT" \
  --max-escalations "${MAX_ESCALATIONS:-5}" --escalation-count "$ESC_COUNT" \
  --control "$CONTROL_ISSUE" ${THEME:+--theme "$THEME"} ${REPO:+--repo "$REPO"} ${ONCE:+--once})"
```

`auto-gate.sh` prints **exactly one** sentinel on stdout:

- `CONTINUE` → run one iteration (§4.2).
- `STOP <reason>` where reason ∈ `{kill-switch, time, max-prs, max-escalations,
  backlog-empty, operator}` → stop the loop, disarm `/loop` + `/schedule`, report.

Priority is fixed (kill-switch → time → budget → backlog → operator). On an empty
backlog without `--once`, the gate idle-backoffs so the run keeps polling. The
result is on **stdout**, not the exit code (non-zero exit = hard arg error).

### 4.2 One iteration = one bounded deliverable (you sequence it)

On `CONTINUE`, run exactly one iteration as the following sequence. Check the
kill-switch (`"${BIN}/auto-kill.sh" --control "$CONTROL_ISSUE"` → `KILLED`/`LIVE`)
at each marked boundary; on `KILLED`, finish the current atomic commit, release the
claim, and stop (`STOP kill-switch`).

1. **PREP (deterministic — engine).** Cold-boot from GitHub, select the next
   eligible issue (`auto:eligible`+`status:ready`, not held/claimed/blocked; priority
   then FIFO), claim it (lease), and cut its worktree+branch from `origin/develop-auto`:

   Generate a **stable runner id for this issue** and pass it (env `AUTO_RUNNER_ID`) to
   BOTH prep and finish, so finish can release the lease prep took:

   ```bash
   RUNNER="auto-runner-${RUN_ID}-$$-${RANDOM}"   # one per issue; reused by step 3.
   PREP="$(AUTO_RUNNER_ID="$RUNNER" "${BIN}/auto-iterate.sh" --phase prep \
     ${THEME:+--theme "$THEME"} --concurrency "${CONCURRENCY:-1}" \
     --control "$CONTROL_ISSUE" --status "$STATUS_ISSUE" --run-id "$RUN_ID" \
     ${REPO:+--repo "$REPO"} ${DRY_RUN:+--dry-run} ${VERBOSE:+--verbose})"
   ```

   It prints `PREP issue=<N|-> size=<S|M|L|XL|-> branch=<name|-> worktree=<path|->
   reason=<token>`. Route on its exit code: `0`+`issue=-` → no work (re-arm/continue);
   `11` → claim lost (continue to next); `13` → concurrency ceiling (back off,
   continue); `2` → kill-switch (clean stop); else `0` → parse `branch` + `worktree`
   (= `$WT`) and proceed to EXECUTE. (prep does its own kill-check right after the claim;
   the claim stays LIVE for steps 2–3.)

2. **EXECUTE — the consensus protocol (you orchestrate; §4.3).** This is where **every
   decision passes through subagent consensus**: build the `GoalArtifact` from the issue →
   **design-consensus** gate (3 biased solvers → meta-judge → ONE concrete plan) → an
   implementer builds ONLY that plan → **review-consensus** gate (3 biased reviewers →
   meta-judge → done/fix). Each accepted change is committed by you — `commit-gate.sh`
   only **validates** (conventional / no `Co-Authored-By` / gitleaks / build-check); on its
   exit 0 you do the actual commit (**never `git commit` before the gate passes**):

   ```bash
   "${BIN}/commit-gate.sh" --dir "$WT" --message "type(scope): subject" \
     && git -C "$WT" commit -m "type(scope): subject"
   ```

   **〈kill-check〉** at each gate / subagent boundary and before each commit.

3. **FINISH (deterministic — engine).** When EXECUTE succeeds (zero blocking findings,
   fast gate green), hand the issue back to the engine — with the SAME runner id — to
   push, open the base-locked PR, merge when green, and release:

   ```bash
   "${BIN}/auto-iterate.sh" --phase finish \
     --issue "$N" --worktree "$WT" --branch "$BRANCH" \
     --control "$CONTROL_ISSUE" --run-id "$RUN_ID" \
     ${CONTEXT:+--context "$CONTEXT"} ${REPO:+--repo "$REPO"} ${DRY_RUN:+--dry-run}   # AUTO_RUNNER_ID="$RUNNER"
   ```

   Finish runs F (push → `auto-pr-create.sh`, base-locked + verified) → G
   (`auto-merge-when-green.sh`: squash, green floor, flaky budget, no force) → release,
   with **kill-checks before push and before the PR open**, and a crash-safe
   `success`-release recorded BEFORE the merge poll (so a crash mid-merge leaves the
   issue safely `status:in-review`, never orphaned). It emits the one terminal `ITER`
   line; route on its exit code (`0`=merged/pr-open progress; `70`–`75`=escalated).

4. **ESCALATE (when consensus cannot converge).** If the **design** meta-judge exits
   `escalate` (true stall, or a `reject`/`delete` the others don't rebut), or the bounded
   **review** fix-loop is exhausted with a `reject` still open, do NOT call finish —
   escalate (human-gated). `auto-release.sh --outcome hard` files the `auto:hold` +
   `status:triage` follow-up **itself** (idempotently), blocks the original, and drops
   `auto:claimed` — so you just call it (don't also file the follow-up yourself):

   ```bash
   "${BIN}/auto-release.sh" "$N" "<reason>" --outcome hard --runner "$RUNNER"
   ```

   Count it toward `ESC_COUNT`.

5. **RE-ARM.** Update the per-run status issue, then re-arm (§4.4). If finish
   `result=merged` increment `PR_COUNT`; if you escalated increment `ESC_COUNT`; pass
   both to the next gate (they back `--max-prs` / `--max-escalations`). The engine's
   `EXIT/INT/TERM` trap releases any still-held claim on a crash.

`--phase prep` emits a `PREP …` line (its outcome is in `reason` + the exit code);
`--phase finish` emits one `ITER <result> issue=<N|-> pr=<N|-> reason=<token>` line
(`result` ∈ `{merged, pr-open, escalated, dry-run, error}`). Surface them (or a rolling
summary) to the user.

> `--concurrency N>1`: run N issues in parallel — each gets its own PREP (lease +
> worktree + branch + PR) and its own EXECUTE fan-out. Because subagents are depth-1,
> **you** (the one session) own all the spawning; interleave the N issues' rounds
> rather than nesting. Default N=1.

### 4.3 EXECUTE — the consensus protocol (design gate + review gate)

`/auto` makes its two real cognitive decisions — **what to build** and **is it done** —
by **subagent consensus** (borrowed from `consensus-rnd`'s `sshx`), never by a single
agent. Spawn each role with the Agent tool as `auto:<role>`; spawn each **triplet in
parallel** so the three are **isolated** — a subagent sees only its dispatch brief (the
`GoalArtifact` + repo/diff), never its peers' output (No Context Pollution). Carry back
only each subagent's compact `conclusion` (verdict + plan/findings); its full reasoning
stays in its own transcript. Inject `--context` (advisory) into every brief. `size` is
informational only — the same protocol runs for every issue. Reviewers/solvers are
read-only; you feed them the **scoped diff** (`git diff origin/develop-auto...HEAD`).

**1 — intake.** Build the `GoalArtifact`: `normalized_goal`, `constraints`,
`success_criteria` (= the issue's **Definition of Done** checklist plus any
acceptance criteria; the fixed target — every item must end up locally
verified), `iteration_question`. Issues specced by `/auto:sa-design` carry the
full Background / Purpose / Affected Files / Implementation Instructions /
Definition of Done sections — feed all five to the solvers; the Implementation
Instructions are the spec the MANDATORY directive binds you to.

**2 — DESIGN consensus (decide the plan).** Spawn the thinking triplet in parallel —
`auto:solver-minimal`, `auto:solver-structural`, `auto:solver-delete` (each →
propose/revise/reject/abstain + a plan). Then `auto:meta-judge` (design mode) applies the
**design truth table** → `implement` (a unanimous concrete plan) / `converge` (merge
compatible plans into ONE) / `escalate` (true stall → ESCALATE §4.2.4) /
`reject-fake-consensus`. The approved **concrete plan** is the ONLY thing implementation
may build — an obvious direction still passes the gate as an evidenced plan.

**3 — implement the approved plan.** Spawn one implementer (`auto:implement-backend` /
`auto:implement-frontend`) with the meta-judge's plan + constraints; it edits only inside
the worktree. Commit each accepted change via the gate then `git commit` (§4.2.2).
`auto:debug` only if the build/tests go red.

**4 — REVIEW consensus (decide done vs fix).** Spawn the review triplet in parallel, each
with the scoped diff + the `GoalArtifact` — `auto:reviewer-requirements`,
`auto:reviewer-quality`, `auto:reviewer-tests` (each → approve/comment/reject). Then
`auto:meta-judge` (review mode) applies the **review truth table** → `fix` (any reject) /
`done` (no reject + ≥1 approve) / `another-pass-or-ask` (all comment). **Requirements
conformance is mandatory**: if `auto:reviewer-requirements` does not `approve` (the diff
does not provably meet 100% of `success_criteria`), the exit is `fix` regardless — this is
/auto's "100% meets requirements" guarantee. `auto:review-secrets-leaks` runs as a
standing hard gate alongside (complements the commit-gate gitleaks scan).

**5 — fix loop (bounded).** On `fix`: an implementer applies the SMALLEST change that
closes the meta-judge's `blocking` items (each tied to a `success_criterion`), commit via
the gate, then re-run the REVIEW consensus. Bound the fix passes at `AUTO_ROUNDS_CEILING`
(5); on exhaustion, ESCALATE (§4.2.4). On `done`, EXECUTE succeeds → FINISH (§4.2.3).
Persisting anything to a file is done only by `auto:write-documentation`.

The deterministic gates around this — claim, commit-gate, base-locked PR, green-floor
auto-merge, kill-switch — are unchanged; **consensus governs only the cognitive decisions**
(the plan, and done-vs-fix), exactly as you asked.

### 4.4 Re-arm — the 双保险 (Claude Code native)

After each iteration, re-arm so `/auto` survives both in-session and out-of-session:

1. **PRIMARY — `/loop` (self-paced, in-session).** Re-arm immediately after each
   iteration (durations vary ~20×, so self-pace; don't pin a fixed interval). Each
   tick: gate (§4.1) → iterate (§4.2) → re-arm.
2. **WATCHDOG — `/schedule` (out-of-session resurrection).** Arm a durable cloud cron
   routine at `7,17,27,37,47,57 * * * *` (10-min, off-zero). It is a **resurrection
   check, not a runner**: it reads state from GitHub and, if the run is active but the
   in-session loop is dead (lease stale / heartbeat old), relaunches `/loop` with the
   **same** run id, start, control/status issues, and flags. It runs in Anthropic's
   cloud, so it keeps `/auto` alive even with your machine off. Durable routines expire
   after ~7 days and self-re-arm within ~12h of expiry — tell the user the 7-day limit
   at start.

**Disarm on terminal state.** When the gate prints `STOP <reason>` (or the user asks
to stop): cancel `/loop`, delete the `/schedule` routine, release any held claim,
mark the per-run status issue terminal, and report. Do **not** touch `auto:stop` on
`#auto-control` — a human owns that.

---

## 5. The kill-switch (single canonical contract)

There is exactly **one** kill-switch check — `bin/auto-kill.sh` — used identically by
the gate, your in-iteration boundary checks, and the `/schedule` watchdog. A run is
KILLED if **either**:

1. **PRIMARY** — label `auto:stop` on the pinned `#auto-control` issue (one tap on
   GitHub mobile, or `gh issue edit <ctrl#> --add-label auto:stop`).
2. **FALLBACK** — file `.auto/STOP` on the `develop-auto` branch (read *remotely* via
   `gh api`, so a local `.gitignore` is irrelevant).

Check it at the five points in §4.2 (iteration top via the gate; just after claim;
each subagent/phase boundary; before commit/push; before opening the PR). Results
cache 20s (`AUTO_KILL_POLL_CACHE`). Kill is **cooperative**: the current atomic commit
finishes, then the iteration releases its claim and exits; the gate prints
`STOP kill-switch`.

You never set or clear `auto:stop` — a **human** owns it. If a fresh `/auto` finds it
set, preflight A12 refuses to start. **Resume** is a human removing it; the next loop/
cron tick auto-resumes from GitHub state. Tell the user both stop methods at run start.

---

## 6. Concurrency, claims, and state (what to trust)

- `--concurrency N` parallelizes **issues**: up to N, each with its own lease +
  worktree + branch + PR. Default N=1. Subagent fan-out within an issue is always
  flat/depth-1 and separate from this.
- The claim is **CAS-free and additive** (`bin/auto-claim.sh`): add `auto:claimed`,
  assign the active gh account, post an authoritative **lease comment**; resolve races
  by deterministic tie-break on server `createdAt` (oldest wins, ties by runner id). The
  global concurrency ceiling is **probabilistic** (TOCTOU-honest); the per-issue lease
  prevents double-work on the *same* issue. Don't add a second lock.
- **Multiple instances are supported by default — one loop per project directory.**
  Claude Code session A may run `/auto:sa-implement` on project A while session B
  runs it on project B (and so on): every piece of engine state is per-repo
  (`.auto/` under each repo root, per-repo run ids, per-issue GitHub leases) and
  the engine never mutates machine-global state (no `gh auth switch`, no global
  git config writes), so instances cannot interfere. Two loops on the SAME repo
  clone also won't double-work an issue (the lease wins), but the supported
  pattern for parallelism within one repo is a single loop with `--concurrency N`.
- **Durable state is GitHub** (issues/labels/PRs/comments). `.auto/` is disposable
  cache, gitignored, **never committed**. The only thing that lives on `develop-auto`
  outside the PR flow is the human-flippable `.auto/STOP`. Re-derive from GitHub at the
  top of every iteration.
- Logging: the engine appends NDJSON to `.auto/log/YYYY-MM-DD.ndjson` at
  INFO/DEBUG/ERROR. Don't read it back into context; surface ERROR events from the
  per-run status issue if the user asks how the run is going.

---

## 7. `--dry-run` semantics (faithful rehearsal, zero mutation)

`--dry-run` runs the **full pipeline up to but not including any remote mutation**:
preflight (read-only, still **aborts** on unmet prereqs) → gate → PREP with a
**simulated** claim → EXECUTE **planning only** (read-only subagents may run
analysis/architecture; **no file writes, no commits**) → print the intended branch
name, commit plan, PR title/body, and the parity/auto-merge decision table.

**No-ops under `--dry-run`:** claim writes, branch push, commits, `gh pr create`,
auto-merge, escalation issue creation, label mutations, and control/status issue
creation. Thread `--dry-run` to `auto-preflight.sh`, `auto-seed.sh`, and every
`auto-iterate.sh`/PR/merge call. Report the decision table and stop (a dry-run does
not arm the loop).

---

## 8. End-to-end playbook (the order you execute in)

1. **Parse** flags (§1); resolve `RUN_ID`, `START_EPOCH`. Echo the resolved plan.
2. **Preflight** (§2). On non-zero, **STOP**, report the exact condition + remediation,
   **WAIT**. On success capture `CONTROL_ISSUE` + `STATUS_ISSUE`.
3. **Seed** (§3) if `--seed`. If `--seed-only`, stop & report.
4. **Dry-run** (§7) if `--dry-run`: drive the pipeline read-only, print the decision
   table, stop. (Do not arm the loop.)
5. **Arm continuity** (§4.4): `/loop` (self-paced) + `/schedule` watchdog, sharing run
   id / start / control+status issues / flags.
6. **Loop each tick** (§4): gate → on `CONTINUE`, run the iteration sequence (PREP →
   EXECUTE with `auto:<role>` subagents → commit-gate → PR → merge → release) →
   re-arm. On `STOP <reason>`, **disarm**, release any claim, mark status terminal,
   report.
7. **Kill-switch** (§5): checked at every boundary; a human flipping `auto:stop` halts
   the run cooperatively and persists across runs.

Output policy (binds to the MANDATORY directive above): echo the resolved plan,
the preflight verdict, and the two stop methods at run start — then go quiet.
Interim progress lives in the per-run status issue (and the engine's `ITER`
lines), not the conversation. The user-facing report comes at the terminal
state: all in-scope issues implemented and fully verified working end to end, or
the stop reason plus exactly what is and is not done. The deterministic logic
lives in `bin/` + `lib/`; you sequence and run subagents, you do not reimplement.

---

## 9. References (read for detail; do not duplicate their logic here)

- `references/architecture.md` — canonical design doc (hard constraints, all phases).
- `references/conventions.md` — branch/commit/label/routing/escalation rules.
- `references/state-model.md` — GitHub-as-state, lease/kill-switch.
- `lib/constants.sh` — labels, exit codes, timing, markers (string source of truth).
- `lib/roles.sh` — role → capability-class (the write/read-only split mirrored in
  each `agents/<role>.md` `tools:` grant).
- `agents/<role>.md` — the 12 role subagents you spawn as `auto:<role>`.

Script contracts you invoke (read each script's header for exact flags):
`bin/auto-preflight.sh`, `bin/auto-seed.sh`, `bin/auto-gate.sh`,
`bin/auto-iterate.sh` (`--phase prep`), `bin/auto-kill.sh`, `bin/commit-gate.sh`,
`bin/auto-pr-create.sh`, `bin/auto-merge-when-green.sh`; (engine-internal, invoked by
the above): `bin/auto-claim.sh`, `bin/auto-worktree.sh`, `bin/build-check.sh`,
`bin/ci-parity-check.sh`, `bin/auto-release.sh`, `bin/auto-stale.sh`.
