# /auto — Interface Contract (pinned)

> Authority order: `architecture.md` (canonical) > this file. This is the pinned
> interface contract for the /auto codebase: the exit-code table, every `bin/*.sh` CLI
> contract, every public `lib/*.sh` function, and the on-GitHub / on-disk schemas.
> **It is authored from the code as built.** Where this prose and `lib/constants.sh`
> ever disagree, `constants.sh` wins (it is the string source of truth). Marker
> strings, codes and timings mirror `constants.sh` and `references/state-model.md`
> exactly. (Role workers are `auto:<role>` subagents spawned by the agent session via
> the host's native subagent mechanism — there is no adapter layer.)

---

## Exit codes

All codes come from `lib/constants.sh §10` (decisions.md §6) and are pinned exactly.
A function/script that "logs ERROR + returns EX_*" propagates the code under `set -e`.

| Constant | # | Meaning |
|----------|---|---------|
| `EX_OK` | 0 | Success. |
| `EX_ERR` | 1 | Generic error (incl. argument / dependency errors). |
| `EX_CHECK_FAIL` | 2 | Check / parity / build FAIL; also the value of `EX_PREFLIGHT_KILLSWITCH` (a pre-set kill switch is a clean refusal-to-start, not a misconfig). |
| `EX_CLAIM_LOST` | 11 | Lost the claim race (a different runner holds / won the live lease). |
| `EX_NOT_CLAIMABLE` | 12 | Issue not in a claimable state (closed / held / stopped / blocked / not eligible). |
| `EX_PREFLIGHT_ORIGIN` | 60 | A1: no GitHub `origin` remote. |
| `EX_PREFLIGHT_AUTH` | 61 | A2: `gh` not authed / missing `repo`+`workflow` scopes. |
| `EX_PREFLIGHT_BRANCHES` | 62 | A3: `develop` and/or `develop-auto` missing on origin. |
| `EX_PREFLIGHT_YAML` | 63 | A4: no YAML parse capability (yq / PyYAML / vendored miniyaml.py). |
| `EX_PREFLIGHT_PARITY` | 64 | A5: CI parity FAIL. |
| `EX_PREFLIGHT_REVIEW` | 65 | A6: `develop-auto` requires reviews and no second approver configured. |
| `EX_PREFLIGHT_GREENFLOOR` | 66 | A7: empty (or asymmetric-empty) required-check set on `develop-auto`. |
| `EX_PREFLIGHT_SQUASH` | 67 | A8: squash merge disabled on the repo. |
| `EX_PREFLIGHT_GITLEAKS` | 68 | A9: `gitleaks` not installed. |
| `EX_PREFLIGHT_ACCOUNT` | 69 | A10/A11: account selection ambiguous / wrong active gh account / identity not pinned. |
| `EX_PREFLIGHT_KILLSWITCH` | 2 | A12: kill-switch already engaged at start (aliases `EX_CHECK_FAIL`). |
| `EX_PR_BASE_LOCK` | 70 | Base-lock violation (requested base != `develop-auto`). |
| `EX_PR_PUSH` | 71 | Push fail / branch-origin (derives-from-base) violation. |
| `EX_PR_VERIFY` | 72 | Post-create base-verify fail (PR base drifted). |
| `EX_PR_NOT_GREEN` | 73 | Required checks not green / PR not open / poll timeout. |
| `EX_PR_GREEN_FLOOR` | 74 | Green-floor: required-check set empty → refuse merge. |
| `EX_PR_CONFLICT` | 75 | Merge conflict not resolvable without force-push. |

### Gate / terminal sentinels (`constants.sh §11`)

`auto-gate.sh` prints exactly `CONTINUE` or `STOP <reason>` on stdout (the **decision
is the line, not the exit code**). `<reason>` tokens: `kill-switch`, `time`,
`max-prs`, `backlog-empty`, `operator`, `max-escalations`.

---

## bin/ scripts

All scripts source `constants.sh` + `log.sh` (most also `gh.sh`/`git.sh`), set
`set -euo pipefail`, accept `-h|--help` (prints the header block, exits 0), and emit
human/diagnostic lines to **stderr** via `log_*`. Mutating scripts call
`gh_select_account` first → `69` on failure. Unknown flags → `log_error` + exit `1`.

### `auto-preflight.sh` — preflight orchestrator

```
auto-preflight.sh [--run-id <id>] [--no-status-issue]
```

- **stdin:** none.
- **stdout:** the `PASS <id> <detail>` / `ABORT <code> <reason>` line from each
  assertion A1..A12, then on success two result lines: `CONTROL_ISSUE <number>` and
  `STATUS_ISSUE <number|->` (`-` under `--no-status-issue`).
- Runs A1, A2, A10 (account pin first), then A3..A9, A11; installs labels +
  locates/creates `#auto-control` and the per-run status issue; then A12.
  (No adapter self-test — role workers are native subagents.)
- **exit:** `0` on full PASS; otherwise the failing assertion's unique code
  (`60..69`, or `2` for A12); `1` on bad arg / `60` if owner/repo unresolvable.

### `auto-iterate.sh` — the deterministic finish phase of one iteration

```
auto-iterate.sh --phase finish --issue <N> --worktree <path> [--branch <name>]
                               [--control <issue#>] [--run-id <id>]
                               [--repo <owner/repo>] [--verbose]
```

- **finish** (phases F–G): push → base-locked PR → green squash-merge → release, with
  kill-checks before push and before PR open, and a crash-safe `success`-release recorded
  BEFORE the merge poll. **stdout:** `ITER <result> issue=<N|-> pr=<N|-> reason=<token>`,
  `result ∈ {merged, pr-open, escalated, error}`.
- **EXECUTE** (before finish) is the agent SESSION's job — the agent session
  spawns the `auto:<role>` subagents via the host's native subagent mechanism and commits
  each accepted change via `commit-gate.sh`.
- Pass the SAME `AUTO_RUNNER_ID` (env) used by the claiming `prep` (in `auto-api.sh`) so
  finish releases the lease prep took. An EXIT/INT/TERM trap releases any unreleased claim
  on crash.
- **exit:** `0` (progress / clean no-op); `2` (kill-switch); `11` (claim lost);
  `69` (account); `70`..`75` (PR/merge failures, after best-effort
  escalation); `1` (arg error).

### `auto-daemon.sh` — the long-running deterministic orchestrator (continuity)

```
auto-daemon.sh start --repo <url> --account <name> --assignee <user>
                     [--label <L> | --theme <L>]
                     [--duration <X> | --until <T>] [--once] [--max-prs <N>]
                     [--max-escalations <N>] [--poll-interval <S>]
                     [--report-timeout <S>] [--verbose]
                     # queue is filtered to issues ASSIGNED TO <user>, optionally also
                     # carrying <label>. --repo/--account/--assignee are required.
auto-daemon.sh stop
auto-daemon.sh status
```

- **Continuity lives here, not in the agent host.** This bash daemon owns cadence, queue
  polling, and FIFO triggering; `/loop` and `/schedule` are no longer used. It is
  agent-agnostic — the orchestration loop is deterministic shell.
- **start:** switches `gh` to `<account>` with exactly ONE `gh auth switch --user
  <account>` (operator passing the account = authorization for that one switch), runs
  preflight, then publishes `.auto/daemon/run.env` exporting `AUTO_RUN_ID`,
  `CONTROL_ISSUE`, `STATUS_ISSUE`, `REPO`, `THEME`, `AUTO_GH_ACCOUNT`.
  On preflight success it writes `.auto/daemon/ready`; on preflight failure it writes
  `.auto/daemon/abort` (containing the `ABORT` code) and exits. It then enters the loop.
- **loop / FIFO protocol:** the daemon talks to the agent session over two FIFOs under
  `.auto/daemon/`:
  - `work.fifo` (daemon→session): `ROUND <n> <queue-json>` | `STOP <reason>`.
  - `report.fifo` (session→daemon): `REPORT result=<merged|pr-open|escalated|error|nothing> issue=<N|->`.
- **pacing:** one issue at a time — report-driven while work exists (the next round is
  dispatched only after each `REPORT`); when the queue is empty it idle-polls every ~15m
  (`--poll-interval`, default `900`s).
- **stop:** signals the running daemon to stop. **status:** reports daemon liveness /
  run state.
- **exit:** `0` clean stop / clean status; the preflight `ABORT` code on a failed
  `start` preflight; `1` on bad arg.

### `auto-api.sh` — the agent-facing verb layer (thin dispatcher)

```
auto-api.sh queue
auto-api.sh prep <N>
auto-api.sh commit --dir <wt> --message <msg>
auto-api.sh finish <N> --worktree <wt> --branch <b>
auto-api.sh escalate <N> <reason>
auto-api.sh release <N> <reason>
auto-api.sh kill-check
auto-api.sh status <msg>
```

- The agent NEVER calls `git`/`gh` directly; it drives the (unmodified) engine through
  these verbs. The dispatcher reads `.auto/daemon/run.env` for run context, and persists
  a per-issue runner identity to `.auto/daemon/runner-<N>` so that `prep`'s claim and
  `finish`'s release share ONE runner id.
- **verbs:**
  - `queue` — prints the prioritized eligible-candidates JSON (via `gh_queue_list`).
  - `prep <N>` — claims the SPECIFIC chosen issue `<N>` (via `auto-claim.sh`) and cuts its
    worktree (via `auto-worktree.sh`). **stdout:** `PREP issue=<N> branch=<b> worktree=<path> runner=<id>`.
  - `commit --dir <wt> --message <msg>` — runs the commit-gate then `git commit`.
  - `finish <N> --worktree <wt> --branch <b>` — delegates to `auto-iterate.sh --phase finish`.
  - `escalate <N> <reason>` / `release <N> <reason>` — the corresponding engine actions.
  - `kill-check` — runs `auto-kill.sh` → `KILLED` / `LIVE`.
  - `status <msg>` — posts a status update.
- **exit:** pass-through from the underlying engine script for each verb.

### `auto-gate.sh` — single stop-condition gate (`should_continue`)

```
auto-gate.sh [--until <iso8601|epoch>] [--duration <Nh|Nm|Ns>] [--start <epoch>]
             [--max-prs <n>] [--pr-count <n>] [--max-escalations <n>] [--escalation-count <n>]
             [--control <issue#>] [--repo <owner/repo>] [--theme <label>]
             [--once] [--no-backoff] [--backoff <seconds>]
```

- Priority-ordered stop checks (first match wins): kill-switch (shells `auto-kill.sh
  --quiet`), time (earliest of `--until`/start+`--duration`), `--max-prs`,
  `--max-escalations`, operator sentinel, backlog. Empty backlog: `--once`/`--no-backoff`
  → STOP `backlog-empty`; else idle-backoff (`--backoff`, default `AUTO_IDLE_BACKOFF`=60)
  then re-check.
- **stdout:** exactly one of `CONTINUE` / `STOP <reason>`.
- **exit:** `0` whether CONTINUE or STOP (decision is the line); `1` hard arg/dependency error.

### `auto-kill.sh` — single canonical kill-switch check

```
auto-kill.sh [--control <issue#>] [--repo <owner/repo>] [--no-cache] [--quiet] [--clear-cache]
```

- PRIMARY: `auto:stop` label on `#auto-control` (located via `AUTO_CONTROL_MARKER` if
  `--control` omitted). FALLBACK: `.auto/STOP` on `develop-auto` via the contents API.
  Result cached `AUTO_KILL_POLL_CACHE`s (20) in `AUTO_KILL_CACHE_FILE`.
  `--clear-cache` deletes the cache and exits `0`.
- **stdout (unless `--quiet`):** `KILLED <source>` (`source ∈ {label, stop-file}`) or `LIVE`.
- **exit (the contract is inverted, grep-style):** `0` == KILLED (caller must stop);
  `1` == LIVE (may continue); other `EX_*` only on a hard arg error.

### `auto-claim.sh` — CAS-free per-issue claim

```
auto-claim.sh <issue#> [--kind claim|reclaim]
```

- Phase A gate (one read) → B precheck → C additive write (`+auto:claimed`,
  `-auto:eligible`, lease comment, assignee) → D jittered re-read + deterministic
  tie-break. `--kind reclaim` is auto-forced when only stale-reclaimable. Pins account.
- **stdout:** on WIN, the winning `RUNNER_ID` (last line).
- **exit:** `0` won; `11` lost; `12` not claimable; `69` account; `1` arg error.

### `auto-release.sh` — release a claim on success / failure / crash

```
auto-release.sh <issue#> <reason> [--outcome success|recoverable|hard]
                [--pr <url-or-#>] [--runner <id>]
```

- Always run via an EXIT/INT/TERM trap. Outcome inferred from `<reason>` unless
  `--outcome`: `success|done-pr|pr-open|pr-opened`→success; `hard*|blocked*|escalate*|
  max-rounds|rounds-exhausted|rearm-exhausted`→hard; everything else→recoverable
  (fail-safe). success→`status:in-review`+`done-pr` lease; recoverable→re-queue
  (`+auto:eligible`, `release` lease); hard→`status:blocked` + files a human-gated
  (`auto:hold`+`status:triage`) escalation issue. Pins account.
- **stdout:** none on the happy path (log lines to stderr).
- **exit:** `0` applied (or already released); `69` account; `1` arg error.

### `auto-stale.sh` — scan + reclaim dead leases

```
auto-stale.sh [--limit N] [--reclaim] [--no-reclaim] [--quiet]
```

- Default reclaims (`--no-reclaim` forces report-only). Reclaimable iff OPEN, not
  held/stopped/blocked, newest lease older than `AUTO_LEASE_TTL`, no open PR. Reclaim
  delegates to `auto-claim.sh <N> --kind reclaim`. `--limit` default 200. Pins account.
- **stdout (unless `--quiet`):** per candidate `RECLAIMED <N> <runner>` / `LOST <N>` /
  `SKIP <N> <why>`, then `SUMMARY scanned=<a> reclaimed=<b> skipped=<c>`.
- **exit:** `0` scan complete; `69` account; `1` arg error / could not list.

### `auto-worktree.sh` — per-issue worktree lifecycle

```
auto-worktree.sh add    --issue <N> --type <t> --title <title> [--branch <b>]
                        [--repo <owner/repo>]
auto-worktree.sh remove --issue <N> [--keep-branch] [--no-pr-check] [--repo <owner/repo>]
auto-worktree.sh prune
```

- `add`: prune, reuse-or-create worktree at `.auto/worktrees/issue-<N>` on branch
  `auto/<type>/<N>-<slug>` from `origin/develop-auto`.
  `remove`: force-remove worktree; deletes the local branch only when no open PR backs
  it (overridden by `--keep-branch`/`--no-pr-check`).
- **stdout:** `add` prints the worktree path.
- **exit:** `0`; `1` arg / missing subcommand.

### `auto-pr-create.sh` — the only sanctioned PR-creation path

```
auto-pr-create.sh --head <branch> --issue <N> --title <title>
                  (--body-file <path> | --body <text>) [--label <name>]... [--draft]
                  [--base <branch>] [--dir <path>]
```

- Guard 1 pre-create base-lock (`--base` must equal `develop-auto`) → Guard 2
  branch-derives-from-base + push → Guard 3 post-create `baseRefName` re-verify (closes
  PR on drift). Pins account; never force-pushes. `--dir` default `AUTO_ROOT`/cwd.
- **stdout:** the created PR number (last line) on success.
- **exit:** `0`; `69` account; `70` base-lock; `71` push/branch-origin; `72`
  base-verify; `1` arg error.

### `auto-merge-when-green.sh` — poll required checks + squash-merge into develop-auto

```
auto-merge-when-green.sh --pr <N> [--issue <N>] [--dir <path>] [--escalate-cmd "<cmd>"]
```

- Green-floor check; local poll of `gh pr checks --required` until green/timeout
  (`CHECK_POLL_INTERVAL`/`CHECK_POLL_TIMEOUT`); bounded flaky reruns (`FLAKY_RETRY_MAX`);
  conflicts via `gh pr update-branch` only (no force). Squash-merge, body scrubbed
  empty. `--escalate-cmd` is invoked on terminal failure as `<cmd> _ <pr#> <reason>`
  (`reason ∈ {ci-failure, ci-timeout, conflict}`). Pins account.
- **stdout:** log lines (human) to stderr; no stable single sentinel on stdout.
- **exit:** `0` merged; `69` account; `72` base drift; `73` not green / not open /
  timeout; `74` green-floor empty; `75` conflict; `1` arg error.

### `commit-gate.sh` — mandatory pre-commit gate

```
commit-gate.sh (--message-file <path> | --message "<text>") [--dir <path>] [--skip-build]
```

- Four gates: (1) reject any `Co-Authored-By:` line; (2) require a conventional subject
  `type(scope)!: subject` (types `feat|fix|chore|spike|docs|test|perf|refactor|build|
  ci|style|revert`); (3) `gitleaks protect --staged --redact` — **absence is a hard
  fail**; (4) run `build-check.sh` (skippable via `--skip-build`). Does NOT itself
  commit. `--dir` default `AUTO_ROOT`/cwd.
- **stdin:** none. **stdout:** `[commit-gate] OK` on pass (rejection messages to stderr).
- **exit:** `0` all passed (caller may commit); `2` build-check reported a check fail;
  `1` any other gate rejected (co-author / non-conventional / gitleaks / build error) or arg error.

### `build-check.sh` — fast buildable-per-commit gate

```
build-check.sh [--dir <path>]
```

- Override order: `auto.config.json` `.buildCheck` (`enabled:false`→skip-with-WARN;
  non-empty `.buildCheck.commands[]`→run in order, fully replacing detection) → Node →
  Python (pytest) → Go → Make `check` → no-op-with-WARN. `--dir` default `AUTO_ROOT`/cwd.
- **stdin:** none. **stdout:** log lines (human) to stderr.
- **exit:** `0` passed / no-op-WARN / disabled; `2` build/test FAILED; `1` internal/arg error.

### `ci-parity-check.sh` — verify CI parity between develop-auto and develop

```
ci-parity-check.sh
```

- Three layers (all must PASS): triggered-check-name parity, required-status-check
  parity (classic protection ∪ rulesets), cross-consistency. Uses
  `lib/parse_wf.py` + `lib/branch_match.py`. Workflows on the exclusion list /
  carrying `# auto:exclude-from-parity` are dropped from both branches.
- **stdin:** none. **stdout:** `PASS ci-parity` (exit 0) or `FAIL ci-parity` (exit 2);
  failing item types + diverging elements (and WARNs) go to stderr.
- **exit:** `0` parity holds; `2` (`EX_CHECK_FAIL`) on FAIL / no repo / missing helper.

> `lib/branch_match.py`, `lib/miniyaml.py`, `lib/parse_wf.py` are Python helpers
> invoked by `ci-parity-check.sh`/preflight; their CLI contracts are out of scope of
> this shell-interface doc.

---

## lib/ functions

All libs use idempotent double-source guards (`AUTO_<X>_SOURCED`) and are **sourced,
never executed**. Convention: a function prints its primary result to **stdout**
(one value/line), diagnostics to stderr via `log_*`; boolean predicates return `0`
(true) / non-zero (false) and print nothing; hard failures log ERROR-with-cause and
**return** the relevant `EX_*` (they do not `exit`).

### `lib/constants.sh`

Defines all `readonly` constants (version, branch policy, account identity, label
taxonomy `AUTO_LABEL_*`, exit codes `EX_*`, lease/CI/round timings, marker prefixes,
`.auto/` cache paths). No functions. Sets/exports `AUTO_ROOT` (repo root or cwd) and
`AUTO_VERBOSE`. Required tools: `git gh jq python3` (+ `gitleaks` before commit).

### `lib/log.sh`

| Function | Args | stdout / exit | Side effects |
|----------|------|---------------|--------------|
| `log_info` | `<evt> [msg...]` | exit 0 | INFO line to stderr + NDJSON journal. |
| `log_debug` | `<evt> [msg...]` | exit 0 (no-op unless `AUTO_VERBOSE=1`) | DEBUG line to stderr + NDJSON. |
| `log_error` | `<evt> <cause> [msg...]` | exit 0 | ERROR line to stderr + NDJSON; `cause` required. |

Context fields read from env: `AUTO_RUN_ID`, `AUTO_ISSUE`, `AUTO_PHASE` (default `-`).
NDJSON is appended to the per-day journal (`mkdir -p` on demand; best-effort, never
aborts the caller). Internal: `_auto_log_ts`, `_auto_log_path`, `_auto_json_escape`,
`_auto_log_emit`.

### `lib/roles.sh`

| Function | Args | stdout / exit | Side effects |
|----------|------|---------------|--------------|
| `role_is_writer` | `<role>` | exit 0 if write-capable else 1; no stdout | none |
| `role_class` | `<role>` | prints `write_capable`\|`read_only`; exit 0 | none |
| `role_allowed_tools` | `<role>` | prints the Claude `--allowedTools` string; exit 0 | none |

Writers (`AUTO_WRITE_ROLES`): `implement-backend implement-frontend
write-documentation` → `AUTO_TOOLS_WRITER` = `Read,Edit,Write,Bash,Grep,Glob`. Any
other / unknown role → read-only (fail-safe) → `AUTO_TOOLS_READONLY` =
`Read,Grep,Glob,Bash(git diff:*),Bash(git log:*)`.

### `lib/gitleaks.sh`

| Function | Args | stdout / exit | Side effects |
|----------|------|---------------|--------------|
| `gitleaks_present` | — | exit 0 if `gitleaks` on PATH else 1 | none |
| `gitleaks_assert_present` | — | prints version + exit 0, or returns `EX_PREFLIGHT_GITLEAKS` (68) | logs |
| `gitleaks_config_path` | `[worktree-path]` | prints repo-local `.gitleaks.toml`, else shipped baseline, else empty | none |
| `gitleaks_scan_staged` | `[worktree-path]` | exit `0` clean / `2` (`EX_CHECK_FAIL`) secrets-or-scan-error / `68` not installed | runs `gitleaks protect --staged --redact --no-banner`; redacted report → stderr |

### `lib/git.sh`

| Function | Args | stdout / return | Side effects |
|----------|------|-----------------|--------------|
| `git_slugify` | `<text>` | prints branch-safe slug (`x` on empty); exit 0 | none |
| `git_branch_name` | `<type> <issue#> <title>` | prints `auto/<type>/<N>-<slug>` (unknown type→`chore`); exit 0 | none |
| `git_fetch_base` | — | exit 0 / `EX_ERR` | `git fetch --prune origin develop-auto` |
| `git_base_tip` | — | prints `origin/develop-auto` SHA; `EX_ERR` if absent | none |
| `git_worktree_path` | `<issue#>` | prints `.auto/worktrees/issue-<N>`; exit 0 | none |
| `git_worktree_prune` | — | exit 0 | `git worktree prune` |
| `git_worktree_add` | `<issue#> <branch>` | prints worktree path; `EX_ERR` on fail | fetch+prune; reuse-or-`git worktree add -B <branch> ... origin/develop-auto` |
| `git_worktree_remove` | `<issue#>` | exit 0 (idempotent) | force-removes worktree dir + prunes |
| `git_delete_local_branch` | `<branch>` | exit 0 (best-effort) | `git branch -D` |
| `git_is_ancestor` | `<ancestor> <descendant>` | exit 0/1 | none |
| `git_branch_derives_from_base` | `<head-branch>` | exit 0/1 (`EX_PR_PUSH` mapped by caller) | fetches base |
| `git_push_head` | `<branch> [worktree-path]` | exit 0 / `EX_PR_PUSH` | `git push -u origin <branch>`; refuses non-`auto/*` heads and any force |
| `git_pr_update_branch` | `<pr#>` | exit `0` / `EX_PR_CONFLICT` (75) / `EX_ERR` | `gh pr update-branch` (merge-from-base, no force) |
| `git_has_staged_changes` | `[worktree-path]` | exit 0 if staged changes else 1 | none |

### `lib/gh.sh`

The only sanctioned GitHub path (uses the `gh` CLI, never the MCP). Account selection
is deterministic: `auto-daemon.sh start` performs exactly ONE `gh auth switch --user
<account>` up front, then the engine snapshots that account and hard-refuses any later
drift (`EX_PREFLIGHT_ACCOUNT`=69) — the lib functions themselves never switch.
Label/assignee edits are additive (set-union); comments are append-only; PR-by-head
uses the strongly-consistent refs API. `gh_retry <evt> -- <gh
args...>` runs each gh call once per attempt with backoff+jitter on transient errors
and returns gh's exit code.

| Function | Args | stdout / return | Side effects |
|----------|------|-----------------|--------------|
| `gh_active_account` | — | prints active login; `EX_PREFLIGHT_ACCOUNT` if unknown | none |
| `gh_select_account` | — | prints active login; `69` on fail | resolves the ACTIVE local gh login (never switches — `auto-daemon.sh start` already did the one `gh auth switch`), asserts vs the `AUTO_GH_ACCOUNT` pin + `.auto/.account` snapshot, ensures a git identity (missing-only write) |
| `gh_assert_account` | — | prints login; `69` on drift | none (no switch) |
| `gh_repo_slug` | — | prints `owner/repo` (cached); `EX_PREFLIGHT_ORIGIN` on fail | none |
| `gh_auth_ok` | — | exit 0/1 | none |
| `gh_has_scopes` | `<scope...>` | exit 0/1 | none |
| `gh_issue_view` | `<issue#> [json-fields]` | prints issue JSON object | none |
| `gh_queue_list` | `[extra-label]` | prints prioritized eligibility JSON array (P0 first, then number ASC) | none |
| `gh_issue_add_labels` | `<issue#> <label>...` | exit 0 / `EX_ERR` | additive label add |
| `gh_issue_remove_labels` | `<issue#> <label>...` | exit 0 (tolerant/idempotent) | label remove |
| `gh_issue_add_assignee` | `<issue#> [login]` | exit 0 (tolerant) | additive assignee add (default: the resolved run account, else `@me`) |
| `gh_issue_remove_assignee` | `<issue#> [login]` | exit 0 (tolerant) | assignee remove |
| `gh_issue_comment` | `<issue#> <body-string>` | prints created comment URL | append-only comment |
| `gh_issue_comment_file` | `<issue#> <body-file>` | prints comment URL; `EX_ERR` if file missing | append-only comment |
| `gh_issue_comments_json` | `<issue#>` | prints `[{author,createdAt,body}]` (server timestamps) | none |
| `gh_pr_for_head` | `<head-branch> [state]` | prints PR number or empty (refs API, strongly consistent) | none |
| `gh_pr_exists_for_head` | `<head-branch>` | exit 0 if an OPEN PR exists | none |
| `gh_pr_view` | `<pr#> <json-fields>` | prints PR JSON object | none |
| `gh_pr_base` | `<pr#>` | prints PR `baseRefName` | none |
| `gh_pr_required_checks_json` | `<pr#>` | prints `[{name,bucket,state,workflow}]` (pending normalized to array) | none |
| `gh_required_check_contexts` | `<branch>` | prints required-check contexts (sorted, unique; classic ∪ rulesets) | none |
| `gh_required_check_count` | `<branch>` | prints integer count | none |
| `gh_green_floor_ok` | `[branch]` | exit 0 iff non-empty required-check set (or `AUTO_GREEN_FLOOR=0`) | none |
| `gh_rerun_failed_workflow` | `<head-branch> <workflow-name>` | exit 0 (best-effort) | `gh run rerun --failed` |
| `gh_repo_allows_squash` | — | exit 0 iff squash enabled | none |
| `gh_required_review_count` | `<branch>` | prints `required_approving_review_count` (max classic+rulesets, 0 if none) | none |
| `gh_branch_protected` | `<branch>` | exit 0 iff classic protection OR any ruleset | none |
| `gh_remote_file_exists` | `<path> [ref]` | exit 0 iff file exists on `<ref>` (default base) via contents API | none |

### `lib/lease.sh`

Pure jq over the comments JSON (`[{author,createdAt,body}]` as printed by
`gh_issue_comments_json`); no network/git/gh. "Live" = within TTL and not voided by a
later release; winner = newest live `reclaim` else the oldest `createdAt` (tie by
lexicographic runner). All staleness math runs on the server `createdAt`.

| Function | Args | stdout / return |
|----------|------|-----------------|
| `lease_live_owner` | `<comments-json> [now-epoch]` | prints winning live-lease runner, or empty |
| `lease_owned_by` | `<comments-json> <runner> [now-epoch]` | exit 0 iff `<runner>` is the live-lease holder |
| `lease_newest_epoch` | `<comments-json>` | prints createdAt epoch of newest non-release lease, or empty |
| `lease_newest_owner` | `<comments-json>` | prints runner of newest non-release lease, or empty |

### `lib/preflight.sh`

Each assertion `preflight_a<N>_*` runs ONE read-only check (never mutates / never
creates `develop-auto`): on success prints `PASS <id> <detail>` + returns 0; on
failure prints `ABORT <code> <reason>`, logs ERROR, returns the assertion's unique
code.

| Function | Check | Failure code |
|----------|-------|--------------|
| `preflight_a1_origin` | GitHub `origin` remote exists | `60` |
| `preflight_a2_auth` | `gh` authed with `repo`+`workflow` scopes | `61` |
| `preflight_a3_branches` | `develop` + `develop-auto` on origin | `62` |
| `preflight_a4_yaml` | yq / PyYAML / vendored miniyaml.py present | `63` |
| `preflight_a5_parity` | `ci-parity-check.sh` passes | `64` |
| `preflight_a6_review` | review-count compat on `develop-auto` (else `AUTO_APPROVER_TOKEN`) | `65` |
| `preflight_a7_greenfloor` | non-empty (symmetric) required-check set | `66` |
| `preflight_a8_squash` | squash merge enabled on the repo | `67` |
| `preflight_a9_gitleaks` | `gitleaks` installed | `68` |
| `preflight_a10_account` | active gh account == `AUTO_GH_ACCOUNT` | `69` |
| `preflight_a11_identity` | `AUTO_GIT_USER_NAME`/`_EMAIL` pinned + valid | `69` |
| `preflight_a12_killswitch` | `[control-issue#]` — kill-switch clear at start | `2` |
| `preflight_run_all` | `[control-issue#]` — runs A1..A12 in order, stop at first fail | the failing code |

---

## Distribution & orchestration (no adapters)

sa-implement is a **host-neutral SKILL package** (not a Claude plugin). The deterministic
engine is plain bash; orchestration is the bash daemon `bin/auto-daemon.sh`, and the agent
drives the engine through `bin/auto-api.sh`.

- Role workers are **`auto:<role>` subagents** spawned by the agent session via the host's
  native subagent mechanism (fallback, to be wired later: daemon-spawned agent processes).
  Their tools come from each `agents/<role>.md` `tools:` frontmatter (writers get
  Edit/Write; reviewers are read-only).
- Roles ship as `agents/*.md` inside the package (no `define-skill` symlinking; the package
  install places them).
- Continuity is the bash daemon (`bin/auto-daemon.sh`: cadence + queue polling + FIFO
  triggering), not the host — `/loop` / `/schedule` are no longer used.

Historical note: earlier multi-CLI builds had an `adapters/claude.sh` exposing four
capabilities (`define-skill` / `spawn-subagent` / `headless-invoke` / `re-arm`) plus a
`capability-selftest`, so the deterministic core could drive Claude / Codex / Grok / agy /
opencode headlessly. That adapter layer is **removed**.

---

## Schemas

### Lease comment (state-model §2.2)

Any issue comment whose body contains `AUTO_LEASE_MARKER_PREFIX` (`<!-- auto-lease v1`).
Only the marker line's `key="value"` fields are parsed; the prose below is never read.
The lease's effective timestamp is the comment's **server `createdAt`** (converted to
epoch in jq), not the text. As written by the engine:

```
<!-- auto-lease v1 runner="<id>" ttl_seconds="<n>" kind="<kind>" [reason="<r>"] -->

🤖 /auto lease — runner `<id>` ... (kind=<kind>).
```

| Field | Meaning |
|-------|---------|
| `runner` | `"${AUTO_RUNNER_PREFIX}-$(hostname -s)-$$-$(date +%s)-${RANDOM}"`, one per process. |
| `kind` | `claim` \| `renew` \| `reclaim` \| `release` \| `done-pr` (`AUTO_LEASE_KIND_*`). |
| `ttl_seconds` | TTL seconds; `AUTO_LEASE_TTL`=1800. `0` on `release`/`done-pr`. Heartbeat `renew` at `AUTO_LEASE_HEARTBEAT`=900 (TTL/2). |
| `reason` | present on `release`/`done-pr` (the release/done reason). |

> Note: the marker uses `ttl_seconds=` in the code (state-model §2.2 prose abbreviates
> it as `ttl`). The lease parsers (`lib/lease.sh`, `auto-claim.sh`) read `ttl_seconds`.

### `#auto-control` issue (state-model §3.1)

Single, repo-global, permanent, pinned. Located-or-created by preflight. Identified by
the body marker `AUTO_CONTROL_MARKER` (`<!-- auto-control v1 -->`); canonical title
`AUTO_CONTROL_TITLE` (`auto-control`). Hosts the repo-global kill-switch label
`auto:stop` (the only place it lives) which persists across runs until a human removes
it. Never closed; one per repo.

### Per-run status issue (state-model §3.2)

Transient, one per run. Identified by the body marker `AUTO_STATUS_MARKER`
(`<!-- auto-status v1 -->`) and titled with the run id. Updated each iteration with
progress; ERROR-level events also comment here. Unpinned/closed on the run's terminal
state. Never carries `auto:stop`.

### `auto.config.json` (`.github/auto/auto.config.json`)

Committed per-repo config, repo-relative path `AUTO_CONFIG_PATH`. **Every key is
optional** and overrides a `constants.sh` default; hard invariants (base branch,
no-force-push, no-Co-Authored-By, squash, green floor) are NOT configurable.
`schemaVersion` must equal `AUTO_SCHEMA_VERSION` (1). Template shape:

| Key | Shape | Overrides |
|-----|-------|-----------|
| `schemaVersion` | `1` | `AUTO_SCHEMA_VERSION` |
| `account.ghAccount` | string | `AUTO_GH_ACCOUNT` (the pinned run account; normally set by `auto-daemon.sh start --account <name>`, which switches gh to it once and exports it via `run.env`. An empty/omitted config value just means the daemon-supplied account stands) |
| `rounds.{S,M,L,XL}` | int (capped at `AUTO_ROUNDS_CEILING`=5) | `AUTO_ROUNDS_{S,M,L,XL}` (1,2,3,3) |
| `escalations.max` | int | `MAX_ESCALATIONS` (5) |
| `buildCheck.enabled` | bool | `false` → skip the build gate with a WARN (default `true`) |
| `buildCheck.commands` | string[] | non-empty array fully replaces auto-detection; each runs in order, any non-zero fails |
| `parity.exclusionMarker` | string | the first-line parity-exclude marker |
| `parity.excludeWorkflows` | string[] | extra excluded workflow basenames |
| `checks.{pollIntervalSeconds,pollTimeoutSeconds,flakyRetryMax}` | int | `CHECK_POLL_INTERVAL` (30), `CHECK_POLL_TIMEOUT` (3600), `FLAKY_RETRY_MAX` (2) |
| `lease.{ttlSeconds,heartbeatSeconds}` | int | `AUTO_LEASE_TTL` (1800), `AUTO_LEASE_HEARTBEAT` (900) |

> **`buildCheck` is the contract `bin/build-check.sh` reads (authoritative).** Only
> `.buildCheck.enabled` and `.buildCheck.commands[]` are consumed. When `commands` is
> omitted (or empty), the gate auto-detects the ecosystem in a fixed order —
> node (`package.json`) → python (`pytest`) → go (`go.mod`) → make (`Makefile` with a
> `check` target). The auto-detection ecosystems are built into the script, not
> configurable via `auto.config.json`.
