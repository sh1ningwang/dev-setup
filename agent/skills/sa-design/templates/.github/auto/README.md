# `/auto` — operations runbook

`/auto` is an autonomous, 24/7 repository-evolution agent. It drains a GitHub-issue
backlog: it picks an eligible issue, works it in an isolated worktree, opens a small
PR against **`develop-auto`**, and auto-merges when CI is 100% green — then moves to
the next issue, until you stop it.

This document is the operator runbook: **how to stop it**, the **label state
machine**, the **seed pass**, and the **one-time bootstrap** that must be done by a
human before `/auto` can run. (Everything machine-readable lives in
`labels.json`, `auto.config.json`, and `lib/constants.sh`.)

---

## 1. STOP `/auto` (kill-switch)

The kill-switch has two equivalent sources. **Either** halts all pickup within
~20 seconds, and the signal **persists across runs** until a human clears it. It is
checked at five points per iteration; a kill lets the current atomic commit finish
(so commits stay buildable), then the iteration releases its claim and exits.

### Primary — `auto:stop` label (one tap on mobile)

Add the `auto:stop` label to the pinned **`#auto-control`** issue (a single,
repo-global, permanent issue that `/auto` locates-or-creates on first run):

```bash
# find the control issue
gh issue list --search 'in:title auto-control' --state open
# engage the kill-switch
gh issue edit <auto-control#> --add-label auto:stop
```

On GitHub mobile, open the `#auto-control` issue and tap the `auto:stop` label.

### Fallback — `.auto/STOP` file on `develop-auto`

Create an empty file `.auto/STOP` on the `develop-auto` branch. `/auto` reads it
remotely (`gh api .../contents/.auto/STOP?ref=develop-auto`), so your local
`.gitignore` of `.auto/` does not matter:

```bash
gh api -X PUT repos/:owner/:repo/contents/.auto/STOP \
  -f message="engage /auto kill-switch" \
  -f branch="develop-auto" \
  -f content="$(printf '' | base64)"
```

### RESUME

Remove the `auto:stop` label **and** delete `.auto/STOP` (whichever you set). The
next `/loop` tick or cron watchdog auto-resumes. A fresh `/auto` invocation **will
refuse to start** while either signal is set (preflight A12) — this is intentional.

> The kill-switch is the **only** way to stop a healthy run cleanly besides the
> `--duration`/`--until` and `--max-prs` stop conditions and an empty backlog.

---

## 2. Label state machine

The canonical taxonomy is `.github/auto/labels.json` (mirrors `lib/constants.sh`;
do not invent new label names). Install/sync it with:

```bash
bash .github/auto/install-labels.sh
```

### Groups

| Group | Labels | Meaning |
|-------|--------|---------|
| **Control** `auto:*` | `auto:eligible` | `/auto` MAY pick this issue. |
| | `auto:claimed` | A lease is held (lease comment + assignee). Do not touch. |
| | `auto:hold` | Human-gated. `/auto` must NOT pick it (used for escalations). |
| | `auto:stop` | Kill-switch. On the pinned `#auto-control` issue ONLY. |
| | `auto:seeded` | Filed by the `--seed` pass (carries a fingerprint marker). |
| **Lifecycle** `status:*` | `triage` → `ready` → `in-progress` → `in-review` → `done` | Normal flow. |
| | `status:blocked` | Failed/blocked; needs a human. |
| **Priority** | `priority:P0..P3` | P0 highest, P2 default. |
| **Type** | `type:{feature,bug,chore,spike,refactor,docs}` | Sets branch `<type>`. |
| **Size** | `size:{S,M,L,XL}` | Informational scope hint; the same consensus protocol runs for every size. |

### Pickup rule

`/auto` claims an issue **iff** it is `auto:eligible` **and** `status:ready`, OPEN,
and not `auto:claimed` / `auto:hold` / `status:blocked`. Selection orders by
priority (P0→P3), then size (smaller first), then issue age.

### Lifecycle transitions

```
status:triage  ──(human/seed: fully specced)──▶  status:ready + auto:eligible
status:ready   ──(/auto claims)──────────────▶  status:in-progress + auto:claimed
status:in-progress ──(PR opened)─────────────▶  status:in-review
status:in-review   ──(CI green, auto-merge)──▶  status:done + issue closed (Closes #N)
   any          ──(rounds exhausted / hard fail)─▶  status:blocked  (+ follow-up issue:
                                                     auto:hold + status:triage; PR left draft)
```

Escalations are **human-gated**: the follow-up issue is `auto:hold` + `status:triage`
and does **not** re-enter the queue. A run-wide `--max-escalations` ceiling
(default 5) hard-stops the run if escalation chains spike.

---

## 3. Seeding the backlog (`--seed`)

`--seed` turns latent work into structured, deduplicated issues using the Issue
Forms, then files them.

```bash
/auto --seed                          # scan repo signals, file issues
/auto --seed --context "@notes.md"    # also turn a brain-dump into issues
/auto --seed --label area:cli         # scope + tag every seeded issue
/auto --seed --dry-run                # print the create/skip table; mutate nothing
```

**Signals scanned:** `TODO`/`FIXME`/`HACK`/`XXX` comments, failing/skipped tests,
README/doc gaps, dependency drift/advisories, plus each bullet of `--context`.

**Dedup:** every seeded issue body ends with a hidden, location-stable fingerprint
`<!-- auto-seed-fp: <sha1> -->`. Re-seeding **skips** open fingerprints and skips
closed ones (re-file closed only with `--reseed-closed`), so re-running `--seed` is
safe and idempotent.

**Triage gate:** brain-dump and under-specced items are filed `status:triage` (a
human promotes them to `status:ready` + `auto:eligible`). Only fully-specced items
become eligible automatically.

---

## 4. Bootstrap (one-time, human-only)

`/auto` **never** auto-creates branches or CI. Preflight aborts with the exact
unmet condition if any prerequisite below is missing. Do these once:

### 4.1 Branches — both `develop` and `develop-auto` on origin

```bash
git fetch origin
# create develop if it does not exist (from your default branch)
git switch -c develop origin/main && git push -u origin develop   # if needed
# create the auto target FROM develop
git switch -c develop-auto origin/develop && git push -u origin develop-auto
```

`/auto` targets `develop-auto` only; humans promote `develop-auto` → `develop`.

### 4.2 Account

All git/gh operations run as **the account that is active in your local `gh`
CLI** — the engine resolves it at run start, snapshots it, and hard-refuses if
the active login drifts mid-run. It **never** runs `gh auth switch` itself; if
you keep several gh accounts, switch to the one you want *before* launching
(you may also export `AUTO_GH_ACCOUNT=<login>` to make preflight assert the
expected login). Commits use your normal git identity; only when git has no
identity configured does the engine fall back to your GitHub noreply address.
Make sure the account is authenticated with `repo`+`workflow` scopes and that
`develop-auto` requires **zero** approving reviews (an author cannot
self-approve, so any required review count makes autonomous merge impossible).

```bash
gh auth status                          # confirm which account is ACTIVE — that is the one the loop uses
gh auth switch --user <login>           # only if you want a different one (do this BEFORE launching)
```

### 4.3 CI parity + the **green floor** (the most important step)

Two binding rules:

1. **Parity** — CI on PRs → `develop-auto` must be **byte-identical** to CI on
   PRs → `develop`. The simplest way: ensure every workflow's
   `on.pull_request.branches` includes both `develop` and `develop-auto` (or no
   branch filter at all), and that workflow files are identical on both branches.
   `ci-parity-check.sh` verifies this and prints the exact diverging element.

2. **Green floor** — `develop-auto` must require **at least one** status check.
   `/auto` refuses to auto-merge into an **empty** required-check set (that would
   ship unverified code). Configure branch protection (or a ruleset) on
   `develop-auto` to require your CI check(s):

   ```bash
   # example: require a check named "build" on develop-auto, zero reviews
   gh api -X PUT repos/:owner/:repo/branches/develop-auto/protection \
     -H "Accept: application/vnd.github+json" \
     -f 'required_status_checks[strict]=true' \
     -f 'required_status_checks[contexts][]=build' \
     -F 'enforce_admins=false' \
     -F 'required_pull_request_reviews=null' \
     -F 'restrictions=null'
   ```

   The required-check set on `develop-auto` must match `develop`'s (parity binds
   checks, not review count).

### 4.4 Repo settings & tooling

- Enable **squash merge** on the repo (`/auto` merges via squash).
- Install `gitleaks` on every host that will run `/auto` (preflight aborts without
  it). Place the provided `.gitleaks.toml` at the repo root.
- Install the label taxonomy: `bash .github/auto/install-labels.sh`.
- (Optional) Add the server-side backstop `auto-base-guard.yml` to
  `.github/workflows/` on `develop-auto` for defense-in-depth.

### 4.5 Verify

```bash
/auto --dry-run    # runs full preflight + a no-mutation rehearsal; aborts on any
                   # unmet prerequisite and prints the exact condition to fix.
```

When `--dry-run` reports a clean decision table, you are ready to run `/auto`.

---

## 5. Quick reference

| Action | Command |
|--------|---------|
| Stop now | `gh issue edit <auto-control#> --add-label auto:stop` |
| Resume | remove `auto:stop`; delete `.auto/STOP` |
| Seed backlog | `/auto --seed` (add `--dry-run` to preview) |
| Rehearse safely | `/auto --dry-run` |
| Run for a while | `/auto --duration 8h` or `/auto --max-prs 5` |
| Install labels | `bash .github/auto/install-labels.sh` |

State is durable in **GitHub** (issues/labels/PRs); the local `.auto/` cache is
disposable and is reconstructed from GitHub after any crash.
