# /auto — State Model (GitHub-as-state spec)

> Authority order: `decisions.md` (LOCKED) > `architecture.md` > `critique.md` > `spec-*.md`.
> This file is the canonical specification of how /auto stores and recovers state. It
> must match `decisions.md §4` exactly. All marker strings and timing bounds mirror
> `lib/constants.sh`; where prose and `constants.sh` disagree, **`constants.sh` wins**.

---

## 0. Principle: GitHub is the durable state; `.auto/` is disposable cache

Per decisions.md §4 and architecture §7.1:

- **Durable state lives in GitHub** — issues, labels, PRs, and machine-parseable issue
  comments. Everything the engine needs to resume is reconstructable cold from `gh` queries.
- **Local `.auto/` is disposable cache** (gitignored; reconstructed from GitHub if missing).
  Paths from `constants.sh`: `AUTO_STATE_DIR` (`.auto/state/run-<id>.json`),
  `AUTO_WORKTREES_DIR`, `AUTO_LOG_DIR` (NDJSON journal), `AUTO_KILL_CACHE_FILE`,
  `AUTO_STOPFLAG_FILE`. **Never committed to any branch.**
- The **only** thing that ever lives on `develop-auto` outside the PR flow is the optional
  `.auto/STOP` kill sentinel (`AUTO_STOP_FILE_PATH`) — a human-flippable signal read
  remotely, never written by the engine. The blanket `.auto/` working-tree ignore is
  therefore correct and consistent.
- `/auto` never pushes to `develop`/`main` and never pushes to `develop-auto` outside the
  sanctioned PR-merge flow (decisions.md §5).

---

## 1. Label state machine (decisions.md §3, §4)

The lifecycle and control labels (see `conventions.md §3` for the full taxonomy) form the
issue state machine. Transitions are **additive** wherever a race is possible (a loser
never destroys a winner's lease).

### 1.1 Lifecycle transitions

```
                  (filed: form)
                     │
                     ▼
              status:triage ──(human specs it: size + priority + acceptance)──▶ status:ready
                                                                                  + auto:eligible
                                                                                      │
                              /auto selects + claims (§2)                            │
                                     │  add auto:claimed (+ assignee + lease comment) │
                                     ▼                                                ▼
                              status:in-progress ◀───────────────────────────────────┘
                                     │  push + PR opened against develop-auto
                                     ▼
                              status:in-review  ──(bounded rounds; CI 100% green)──▶ status:done
                                     │                                                (PR squash-merged;
                                     │  rounds exhausted / hard failure (§4)           issue closed by Closes #N)
                                     ▼
                              status:blocked  + (follow-up issue: auto:hold + status:triage)
                                     (PR left as draft; claim released; human-gated)
```

### 1.2 Control-label rules

- `auto:eligible` ⊻ `auto:hold` decides eligibility. `auto:hold` always wins (never picked).
- `auto:claimed` is a cheap pre-filter for a held lease; the **lease comment is
  authoritative** (§2), the assignee is cosmetic.
- `auto:stop` lives on the pinned `#auto-control` issue **only** and is repo-global (§3).
- On a clean transition the prior `status:*` label is removed and the new one added; control
  labels (`auto:claimed`) are removed on release. `status:in-progress` + an open PR + the
  live lease comment are the **redundant in-flight markers** used for cold-start
  recovery (§6).

---

## 2. Per-issue lease (claim protocol) — decisions.md §4

The loop works **one issue at a time**; the per-issue lease still prevents two daemon
instances (on different clones) from double-working the same issue. GitHub offers no
compare-and-swap on issue mutations, so the claim is **CAS-free and additive**, resolved by
deterministic tie-break.

### 2.1 Claim = additive writes (`bin/auto-claim.sh <issue#>`)

A claim performs three additive operations:

1. add label `auto:claimed` (cheap pre-filter),
2. assign the active gh account (cosmetic),
3. post a **lease comment** (authoritative).

### 2.2 Lease comment format

A lease is a single issue comment whose body begins with the marker from
`AUTO_LEASE_MARKER_PREFIX` (`<!-- auto-lease v1`) closed on the same HTML-comment line, with
machine-parseable key/value fields:

```
<!-- auto-lease v1 runner="auto-<host>-<pid>-<epoch>-<rand>" kind="claim" ttl="1800" created-at="2026-05-29T12:00:00Z" -->
🔒 Claimed by `auto-<host>-…` (kind=claim, ttl=1800s). Lease renews at TTL/2; reclaimable when stale.
```

Fields (all required):

| Field | Source / meaning |
|-------|------------------|
| `runner` | `"${AUTO_RUNNER_PREFIX}-$(hostname -s)-$$-$(date +%s)-${RANDOM}"`, computed once per process. |
| `kind` | one of `claim`, `renew`, `reclaim`, `release`, `done-pr` (`AUTO_LEASE_KIND_*`). |
| `ttl` | seconds; `AUTO_LEASE_TTL` = 1800 (30m). Heartbeat `renew` posted at `AUTO_LEASE_HEARTBEAT` = 900 (TTL/2). |
| `created-at` | the engine's UTC stamp (advisory). The **server** `createdAt` of the comment is authoritative for tie-break. |

The label `auto:claimed` and the assignee are advisory; the **lease comment set** is the
source of truth.

### 2.3 Winning the race (deterministic tie-break)

1. Write the `claim` lease comment, then sleep a jitter of
   `AUTO_CLAIM_JITTER_MIN..AUTO_CLAIM_JITTER_MAX` seconds (1–3s).
2. Re-read all lease comments on the issue. Compute the **live** set: leases whose server
   `createdAt + ttl > now`.
3. Resolve the winner among live leases:
   - a `kind=reclaim` (newest) supersedes a stale prior holder;
   - otherwise the **oldest `createdAt`** wins; ties break by lexicographic `runner` id.
4. If this process is not the winner, it **self-retracts** (posts a `release` lease) and
   exits `EX_CLAIM_LOST=11`. A dead/expired runner is never in the live set, so it cannot win
   and must re-claim.

### 2.4 Heartbeat & stale reclaim

- Long L/XL issues post a `renew` lease at `AUTO_LEASE_HEARTBEAT` (TTL/2) to keep the lease live.
- `bin/auto-stale.sh`: an issue is reclaimable when the newest **live** lease is older than
  `AUTO_LEASE_TTL` (i.e. expired) **AND** there is **no open PR** for the issue **AND** the
  issue is still OPEN / not `status:blocked`. Reclaim posts `kind=reclaim` (newest →
  supersedes) and re-runs the tie-break.

### 2.5 Idempotent PR creation

Before `gh pr create`, check **both**: `gh pr list --base develop-auto --head <branch>`
(exact head match, strongly consistent via refs — **authoritative**) and the `Closes #N`
search (eventually-consistent — advisory). The head-branch existence check wins, closing the
racy `Closes #N`-only window.

### 2.6 Release (`bin/auto-release.sh <issue#> <reason>`, always via `trap EXIT INT TERM`)

| Outcome | Lease `kind` | Labels |
|---------|--------------|--------|
| Success — PR opened | `done-pr` (+ PR URL in body) | keep/move to `status:in-review`; not re-queued. |
| Recoverable failure | `release` | remove `auto:claimed`, restore `auto:eligible`. |
| Hard failure / rounds exhausted | `release` | `status:blocked`; file follow-up `auto:hold`+`status:triage` (escalation, §4). |

---

## 3. `#auto-control` vs per-run status issue (decisions.md §4 / architecture §3.6)

Two distinct issues, different lifetimes:

### 3.1 `#auto-control` — single, repo-global, permanent

- Located-or-created (idempotent) by preflight. Identified by the body marker
  `AUTO_CONTROL_MARKER` (`<!-- auto-control v1 -->`); canonical title `AUTO_CONTROL_TITLE`
  (`auto-control`); pinned.
- Hosts the kill-switch label `auto:stop` (§4). The label is **repo-global** and **persists
  across runs** until a human removes it: it halts whatever run is active and refuses any
  future run that finds it set.
- Never closed. One per repo.

### 3.2 Per-run status dashboard — transient

- A separate issue per run, identified by the marker `AUTO_STATUS_MARKER`
  (`<!-- auto-status v1 -->`) and titled with the run id.
- Updated each iteration with progress; ERROR-level events also drop a comment here for
  visibility.
- Unpinned/closed on the run's terminal state. Never carries `auto:stop`.

This separation resolves the per-run-vs-repo-global ambiguity: **one permanent control/kill
issue + one transient per-run status issue.**

---

## 4. Kill-switch contract (decisions.md §4 — single canonical contract)

A single function (`bin/auto-kill.sh`) is the **only** kill-switch check, used identically by
the daemon and by the agent session's in-iteration checks. Result is
cached `AUTO_KILL_POLL_CACHE` (20s) per process in `AUTO_KILL_CACHE_FILE` to bound API calls
across the per-iteration check-points.

### 4.1 Two signal sources (either ⇒ stop)

1. **PRIMARY** — label `auto:stop` present on the pinned `#auto-control` issue. One tap on
   GitHub mobile, or `gh issue edit <ctrl#> --add-label auto:stop`.
2. **FALLBACK** — file `AUTO_STOP_FILE_PATH` (`.auto/STOP`) present on the `develop-auto`
   branch, read remotely via `gh api repos/:o/:r/contents/.auto/STOP?ref=develop-auto` (so a
   local `.gitignore` of `.auto/` is irrelevant — the signal is read server-side).

The repo-variable (`AUTO_KILL`) and title-convention sources from earlier lenses are
**dropped**. A local `AUTO_STOPFLAG_FILE` (`.auto/.stopflag`) is an optional operator-local
fast path, not a cross-process source.

### 4.2 Five check-points per iteration (decisions.md §4 / architecture §3.5)

The kill-switch is checked at **exactly five** points each iteration:

1. **Iteration top** (before selecting an issue).
2. **Just after claim** (before any work begins).
3. **Each subagent / phase boundary** (between SDLC phases and review rounds).
4. **Before commit/push.**
5. **Before opening the PR.**

### 4.3 Cooperative stop & resume

Kill is **cooperative**: the current atomic commit finishes (buildable-per-commit invariant
preserved), then the iteration releases its claim (§2.6) and exits cleanly. The gate
(`bin/auto-gate.sh`) prints `STOP kill-switch` (`AUTO_GATE_STOP` + `AUTO_STOP_REASON_KILL`).
A fresh `/auto` that finds `auto:stop` set at start aborts at gate point 1 / preflight A12
with `EX_PREFLIGHT_KILLSWITCH=2` (a clean refusal-to-start, not a misconfiguration — the
driver treats `2` here as "clean stop", not "halt for human").

**Resume** = a human removes `auto:stop` from `#auto-control` (or deletes `.auto/STOP` on
`develop-auto`). The next daemon round re-triggers and resumes from GitHub state.

---

## 5. Re-arm (context-limit continuity — architecture §7.4)

There is **no** checkpoint comment and no shell-level re-arm budget, and there is **no**
`/loop` re-arm. Context limits are handled natively: each role subagent runs in its own
window (heavy work is isolated off the session), and if the agent session itself nears its
context window mid-issue, it **resumes the same issue cold** — purely from GitHub state (open
PR by head + `status:in-progress` + the live lease comment) plus the worktree's existing
commits — and the daemon re-triggers the next round via `work.fifo`. No phase pointer is
persisted; nothing relies on carried agent context (§6).

---

## 6. Cold-start resume (architecture §7.1–7.2)

The top of **every** iteration re-derives 100% of the working set from GitHub — nothing relies
on carried agent context:

1. Query open PRs by head branch (`auto/*`) against `develop-auto`.
2. Query issues by label `status:in-progress` and their lease comments.
3. Re-derive each in-flight issue's progress from that GitHub state — labels, the open PR,
   and the worktree's existing commits. There is no phase pointer to recover.

`status:in-progress` + open PR + the live lease comment are redundant in-flight markers. A `kill -9`
between any two steps leaves a resumable state; commit-early/push-early means at most one
un-pushed phase is redone. Local `.auto/state/run-<id>.json` is a convenience cache only and is
rebuilt from GitHub if missing.

---

## 7. Continuity (daemon) — decisions.md D10 / architecture §7.3

Continuity is a single mechanism: a long-running, deterministic **bash daemon**
(`bin/auto-daemon.sh`) owns the loop's cadence and triggering. It is host-neutral — the
cognitive worker is an interactive **agent session** (OpenCode, Codex, or Claude Code), which
the daemon drives over two FIFOs under `.auto/daemon/`:

- **`work.fifo`** (daemon → session) — carries `ROUND <n> <queue-json>` to trigger a round,
  or `STOP <reason>` to wind down.
- **`report.fifo`** (session → daemon) — carries `REPORT result=<r> issue=<N>` when a round
  completes.

**Pacing** is report-driven while work exists: the daemon pushes a round on `work.fifo`, then
blocks awaiting the `REPORT` on `report.fifo` before pushing the next. When the queue is
empty it falls back to **idle-poll every ~15 minutes** of the GitHub issue queue until work
reappears. The daemon and the agent session both check the **identical** kill-switch (§4); the
session performs git/GitHub mutation only through the verb layer `bin/auto-api.sh`.

This daemon is the **single** continuity mechanism — it replaces the earlier two-mechanism
keep-alive (a self-paced in-session loop plus an out-of-session durable-cron resurrection
watchdog), both of which are removed.

Hand-off has no separate channel: the per-issue claim (§2) is the single mutual-exclusion
mechanism; the loser exits cleanly (`EX_CLAIM_LOST=11`). No second global git-CAS lease exists.

See `references/conventions.md` for branch/commit/label/routing/escalation rules and
`references/architecture.md` for the engine design + daemon orchestration.
