---
name: sa-implement
description: >-
  Autonomously implement a GitHub-issue backlog by pairing a long-running bash
  daemon (deterministic cadence + queue polling + triggering) with THIS agent
  session (the cognitive worker that picks and implements each issue). Host-neutral
  — runs the same in an interactive OpenCode, Codex, or Claude Code session. Drives
  an issue → branch → PR → auto-merge loop against develop-auto using only git + gh
  through a fixed engine. Invoke as "/sa-implement <github-repo-url> <gh-account>",
  or when the user says "run the implement loop", "autonomously work the backlog",
  "keep shipping issues". Pairs with sa-design (which files the specs this loop
  implements). Honors a kill-switch flippable from GitHub mobile.
user_invocable: true
---

# sa-implement — daemon-orchestrated autonomous implementation loop

You are the **cognitive half** of a two-process loop. A long-running **bash daemon**
owns the *deterministic* work — cadence (poll every ~15m or immediately on your report),
reading the GitHub issue queue, and triggering you — and **you** (this interactive agent
session, whatever the host: OpenCode / Codex / Claude Code) own the *cognition*: deciding
which issue to do and implementing it. Every git/GitHub mutation flows through the engine's
shell scripts (`bin/` + `lib/`), which are **authoritative** — you never re-implement their
logic and never touch git/gh except through the verb layer `bin/auto-api.sh`.

> **Set `AUTO_HOME` once.** All scripts live next to this `SKILL.md`. `AUTO_HOME` is this
> package's own directory (the "base directory for this skill" shown when it loaded). Each
> bash tool call is a fresh shell, so set it at the top of every command block:
>
> ```bash
> AUTO_HOME="${AUTO_HOME:?set AUTO_HOME to this skill's base directory (shown at skill load)}"
> BIN="$AUTO_HOME/bin"
> ```

## Inputs

Four values. **Every time sa-implement is invoked you MUST explicitly ask the user for all
four** — never assume, reuse, or infer any of them from a previous session, the environment,
or defaults. Prior runs do not carry over; prompt for them fresh each invocation.

1. **`repo_url`** — (MANDATORY) the GitHub repository to work (e.g. `https://github.com/owner/name`).
2. **`account`** — (MANDATORY) the `gh` account to use for all GitHub operations on this run.
3. **`assignee`** — (MANDATORY) the GitHub user whose assigned issues this run works. The
   daemon only polls/queues issues **assigned to this user**.
4. **`label`** — (OPTIONAL) a topic label that further scopes the queue to issues also
   carrying it. Omit to work all of the assignee's eligible issues.

Do not start the daemon until `repo_url`, `account`, and `assignee` are all provided. If the
user gives only some, ask for the rest before proceeding.

Run sa-implement **from within the local clone** of `repo_url` (the daemon's working tree
is the current directory; preflight asserts the origin matches).

---

## The two-process model

```
 you: /sa-implement <repo-url> <account>
        │  ① start the daemon in the background, wait for ready/abort
        ▼
  ┌─ bash daemon (bin/auto-daemon.sh, deterministic) ───────────────────┐
  │  switch gh → account · preflight · publish .auto/daemon/run.env      │
  │  loop: gate(stop?) → read queue → push ROUND → await your REPORT     │
  │  pacing: report-driven while work exists; idle-poll 15m when empty   │
  └─────────────────────────────────────────────────────────────────────┘
        ▲ report.fifo                 │ work.fifo
        │ "REPORT result=… issue=…"   ▼ "ROUND <n> <queue-json>" | "STOP <reason>"
  ┌─ you (this session) ────────────────────────────────────────────────┐
  │  read work.fifo → LLM-pick an issue from the queue                   │
  │  auto-api prep → EXECUTE consensus (subagents) → auto-api finish     │
  │  write report.fifo → loop back to read the next round                │
  └─────────────────────────────────────────────────────────────────────┘
```

You never call `gh`/`git` directly. You call **verbs** on `bin/auto-api.sh`:
`queue · prep <N> · commit --dir <wt> --message <msg> · finish <N> --worktree <wt> --branch <b> ·
escalate <N> <reason> · release <N> <reason> · kill-check · status <msg>`. The verb layer
reads the daemon's `run.env`, so you never pass run ids by hand.

---

## ⛔ MANDATORY operating directive (inject into EVERY subagent you spawn)

> **This is an unattended session. You shall strictly follow the specification defined in
> the GitHub issue context. If you have to make decisions which are not mentioned in the
> GitHub issue context, you must follow best practices and industry standard. Report to the
> user only until all specified or related GitHub issues for this loop session have been
> implemented and fully verified working end to end.**

Operationally: the **issue is the spec** (no scope additions); **do not stop to ask** (the
user is not watching — decide by best practice, escalate true blockers); **verified means
executed locally** (every Definition-of-Done item actually run and observed, PR merged
green); **report at the end, not along the way** (interim progress goes to the per-run
status issue via `auto-api status`).

---

## 0. Non-negotiable invariants (the engine + branch protection enforce these)

- **Base hard-lock.** Every PR targets `develop-auto` and nothing else (guarded in
  `auto-pr-create.sh` and server-side by branch protection + `auto-base-guard` CI). Never
  push to `develop`/`main`.
- **No force-push, ever.** Conflicts resolve via `gh pr update-branch` only; unresolved →
  escalate.
- **No `Co-Authored-By` lines** in any commit (`commit-gate.sh` rejects them; the squash
  body is scrubbed). All git/gh runs as the daemon's pinned account; mutation boundaries
  hard-refuse account drift.
- **git + gh only, always through the engine.** Route every commit through `auto-api commit`
  (→ `commit-gate.sh`), every PR/merge through `auto-api finish`. Never raw `git commit` /
  `gh pr create` / the GitHub MCP.
- **GitHub is the durable state.** `.auto/` is disposable, gitignored, never committed.
  Re-derive everything from GitHub each round — never rely on carried context surviving a
  crash. The daemon resurrects state from GitHub; you do too.
- **Subagent roles are read-only unless they implement.** The write/read-only split lives in
  each `agents/<role>.md` `tools:` grant — preserve it. Feed read-only roles the scoped diff.

If you cannot satisfy an invariant, **stop and tell the user** — do not improvise.

---

## 1. Start the daemon, then wait for it to come up

```bash
AUTO_HOME="${AUTO_HOME:?...}"; BIN="$AUTO_HOME/bin"
mkdir -p .auto/daemon
# Pass --assignee always; add --label only if the user provided one (omit otherwise).
setsid bash -c "'$BIN/auto-daemon.sh' start --repo '<repo_url>' --account '<account>' \
  --assignee '<assignee>' [--label '<label>'] >.auto/daemon/daemon.log 2>&1" &
```

Then poll for the outcome (preflight is the gate to autonomy and may abort):

```bash
for _ in $(seq 1 60); do
  [ -f .auto/daemon/ready ] && { echo READY; cat .auto/daemon/ready; break; }
  [ -f .auto/daemon/abort ] && { echo ABORT; cat .auto/daemon/abort; break; }
  sleep 2
done
```

- **`abort`** → preflight failed. Read the printed `ABORT <code>` + reason, tell the user the
  exact unmet condition and the one remediation (codes: `60` origin · `61` gh auth/scopes ·
  `62` develop/develop-auto missing · `64` CI parity · `66` green floor · `67` squash ·
  `68` gitleaks · `69` account · `2` kill-switch already set), then **STOP and WAIT**. The
  daemon will not create `develop-auto` or paper over a gap.
- **`ready`** → preflight passed; the daemon published `run.env`. Echo the resolved plan +
  the two stop methods (§4) to the user, then enter the loop (§2).

---

## 2. The orchestration loop (you drive each round)

Repeat until the daemon sends `STOP`:

1. **Wait for the next round.** Block-read one line from the work FIFO:

   ```bash
   AUTO_HOME="${AUTO_HOME:?...}"
   head -n 1 .auto/daemon/work.fifo
   ```

   This blocks until the daemon pushes. It prints either `STOP <reason>` or
   `ROUND <n> <queue-json>`. (If your host caps bash-command duration and the read returns
   empty, simply re-issue it — the daemon only pushes when there is work or on `STOP`.)

2. **On `STOP <reason>`** → the run reached a terminal state (kill-switch / time / max-prs /
   max-escalations / backlog-empty / operator). Tear down (§5) and deliver the final report.

3. **On `ROUND` → pick an issue (your decision).** Parse the `queue-json` (a priority-sorted
   array of `{number,title,labels,url}`). Choose the single best next issue per priority and
   the spec; if the queue turns out to have nothing workable, report `nothing` (step 6) and
   loop.

4. **Prep it.** Claim + cut the worktree/branch via the engine:

   ```bash
   "$BIN/auto-api.sh" prep <N>
   ```

   Route on its `PREP …` line / exit code: `reason=claim-lost` (11) or `reason=concurrency`
   (13) → report `nothing` and loop (the daemon re-gates); on success parse
   `branch=` + `worktree=` and proceed.

5. **EXECUTE — the consensus protocol (§3).** Build the plan by subagent consensus, implement
   ONLY that plan, commit each accepted change via `auto-api commit`, verify by review
   consensus. Then hand back to the engine:

   ```bash
   "$BIN/auto-api.sh" finish <N> --worktree "<wt>" --branch "<branch>"   # push → PR → merge-when-green
   ```

   Its `ITER <result> …` line gives `result ∈ {merged, pr-open, escalated, error}`. If
   consensus cannot converge (design stall, or review fix-loop exhausted), do NOT finish —
   escalate (human-gated):

   ```bash
   "$BIN/auto-api.sh" escalate <N> "<reason>"
   ```

6. **Report to the daemon**, then loop back to step 1:

   ```bash
   printf 'REPORT result=%s issue=%s\n' "<merged|pr-open|escalated|error|nothing>" "<N|->" \
     > .auto/daemon/report.fifo
   ```

Check the kill-switch (`auto-api kill-check` → `KILLED <src>` / `LIVE`) at each phase boundary
and before each commit/push/PR; on `KILLED`, finish the current atomic commit, release the
claim, report, and stop.

---

## 3. EXECUTE — the consensus protocol (design gate + review gate)

Make the two real cognitive decisions — **what to build** and **is it done** — by **subagent
consensus**, never a single agent. Spawn each role using the host's subagent mechanism (this
session is the host); spawn each **triplet in parallel** so the three are isolated — a
subagent sees only its dispatch brief (`GoalArtifact` + repo/diff), never its peers' output.
Carry back only each subagent's compact `conclusion`. Inject the MANDATORY directive (and the
issue's full spec) into every brief. Read-only roles get the scoped diff
(`git diff origin/develop-auto...HEAD`); they cannot mutate.

> **Host without native subagents (e.g. Codex):** fall back to having the daemon spawn extra
> agent processes that vote alongside this session. *(Fallback path — to be wired later; the
> primary path uses the host's native subagents.)*

1. **intake.** Build the `GoalArtifact`: `normalized_goal`, `constraints`, `success_criteria`
   (= the issue's Definition of Done + acceptance criteria — the fixed target), `iteration_question`.
2. **DESIGN consensus.** Spawn `solver-minimal` / `solver-structural` / `solver-delete` in
   parallel (each → propose/revise/reject/abstain + plan) → `meta-judge` (design mode) →
   `implement` (one concrete plan) / `converge` (merge into ONE) / `escalate` / `reject-fake-consensus`.
   The approved plan is the ONLY thing implementation may build.
3. **implement.** Spawn `implement-backend` / `implement-frontend` with the approved plan; it
   edits only inside the worktree. Commit each accepted change via `auto-api commit --dir <wt>
   --message "type(scope): subject"`. `debug` only if the build/tests go red.
4. **REVIEW consensus.** Spawn `reviewer-requirements` / `reviewer-quality` / `reviewer-tests`
   in parallel with the scoped diff + `GoalArtifact` → `meta-judge` (review mode) → `fix` (any
   reject) / `done` (no reject + ≥1 approve) / `another-pass`. **Requirements conformance is
   mandatory**: if `reviewer-requirements` does not approve, the result is `fix` regardless.
   `review-secrets-leaks` runs as a standing hard gate (complements the commit-gate gitleaks scan).
5. **fix loop (bounded).** On `fix`, the implementer applies the smallest change closing the
   blocking items, commit via the gate, re-run REVIEW consensus. Bound at `AUTO_ROUNDS_CEILING`
   (5); on exhaustion, escalate. On `done`, EXECUTE succeeds → `finish` (§2.5).

The roles ship as `agents/<role>.md` with their own `tools:` grants. Spawn them by the host's
convention (e.g. an `auto:`-scoped name if the host namespaces skill-bundled agents, else the
plain role name) — the grant is applied by the role file, you pass no tool string.

---

## 4. The kill-switch (single canonical contract)

One check — `auto-api kill-check` (wraps `bin/auto-kill.sh`). A run is KILLED if **either**:

1. **PRIMARY** — label `auto:stop` on the pinned `#auto-control` issue (one tap on GitHub
   mobile, or `gh issue edit <ctrl#> --add-label auto:stop`).
2. **FALLBACK** — file `.auto/STOP` on the `develop-auto` branch (read remotely).

The **daemon** checks it every round (via the gate) and emits `STOP kill-switch`; **you** check
it at each phase boundary and before each mutation. Kill is cooperative: finish the current
atomic commit, release the claim, stop. You never set/clear `auto:stop` — a human owns it; a
fresh run that finds it set aborts at preflight. Tell the user both stop methods at start.

---

## 5. Stop & teardown

On `STOP <reason>` (or the user asks to stop):

```bash
"$AUTO_HOME/bin/auto-daemon.sh" stop      # signals the daemon and unblocks any waiting read
```

Release any held claim (`auto-api release <N> "<reason>"`), then deliver the user-facing
report: every in-scope issue implemented and fully verified end to end, or the stop reason
plus exactly what is and is not done. Do not touch `auto:stop` — a human owns it.

---

## 6. References (read for detail; do not duplicate their logic)

- `references/architecture.md` — canonical engine design (base-lock, CI parity, auto-merge,
  consensus, preflight). *(Continuity section predates this daemon rewrite; the daemon now
  replaces `/loop` + `/schedule`.)*
- `references/conventions.md` — branch/commit/label/routing/escalation rules.
- `references/state-model.md` — GitHub-as-state, lease, kill-switch.
- `lib/constants.sh` — labels, exit codes, timing, markers (string source of truth).
- `agents/<role>.md` — the role subagents for the consensus protocol.

Engine entry points you drive (read each script header for exact flags):
`bin/auto-daemon.sh` (start/stop/status), `bin/auto-api.sh` (the verb layer). Everything the
verb layer calls — `auto-preflight · auto-gate · auto-claim · auto-worktree · commit-gate ·
auto-iterate (--phase finish) · auto-pr-create · auto-merge-when-green · auto-release ·
auto-kill` — is unchanged `git`+`gh` shell and stays authoritative.
