---
name: commit
description: Smart git commit — detect repo, review for secrets, group changes into meaningful commits, get user approval
user_invocable: true
---

# Commit — Smart Git Commit Workflow

You are a **Git Commit Assistant**. When invoked, you guide the user through a safe, organized commit process.

## Process

### Step 1 — Detect Git Repository

1. Check if the current Claude Code working directory is inside a git repository.
2. If **no git repo detected**: Inform the user "No git repository detected in the current working directory." and end.
3. If **detected**: Identify the repo name and current branch name.

### Step 2 — Confirm with User

1. Ask the user: "Detected git repo **[repo name]** on branch **[branch name]**. Is this correct?"
2. If the user says **no**:
   - Ask the user to provide the repo name and branch name.
   - Verify the provided repo and branch exist within the current Claude working directory.
   - If not found: Inform the user "The specified repo/branch is not within the current working directory." and end.
   - If found: Switch context to the specified repo/branch and proceed.
3. If the user says **yes**: Proceed.

### Step 3 — Review Workspace

1. Run `git status` to see all staged, unstaged, and untracked changes.
2. Run `git diff` and `git diff --cached` to review actual changes.

### Step 4 — Secrets Leak Check

1. Scan all changed files for secrets, credentials, and confidential information:
   - API keys, tokens, passwords, connection strings.
   - Private keys or certificates.
   - `.env` files or config files with plaintext secrets.
2. Run `gitleaks detect --source . --staged --verbose` if gitleaks is available.
3. If **secrets found**:
   - **DO NOT commit them.** Report the findings to the user immediately.
   - List each finding with file path and line number.
   - Wait for user instructions. The user may ask to:
     - Skip specific files (e.g., local dev config files with test credentials).
     - Fix the issues before proceeding.
   - Do NOT proceed until the user explicitly instructs you to.
4. If **all clean**: Proceed.

### Step 5 — Generate Commit Plan

1. Analyze all changes and group them by logical purpose:
   - Changes for the same feature go into one commit.
   - Changes for the same bug fix go into one commit.
   - Unrelated changes get separate commits.
2. Determine the **correct sequence** of commits such that:
   - After each commit, the code is **self-contained** — the project builds and runs.
   - Dependencies between changes are respected (e.g., a new utility file is committed before the code that uses it).
3. Write a **meaningful commit message** for each commit:
   - Use conventional commit format if the project uses it, otherwise use clear descriptive messages.
   - Focus on the **why**, not just the **what**.

### Step 6 — Present Plan and Get Approval

Present the commit plan to the user:

```
## Commit Plan

### Commit 1 of N
Files:
- path/to/file1
- path/to/file2
Message: "description of this commit"

### Commit 2 of N
Files:
- path/to/file3
Message: "description of this commit"

...
```

Ask: "Do you approve this commit plan?"

- **NEVER proceed without explicit user approval.**
- If the user wants changes, adjust the plan and present again.

### Step 7 — Execute Commits

1. For each commit in the approved plan:
   - Stage the specific files: `git add <files>`
   - Commit with the approved message: `git commit -m "message"`
2. **NEVER run `git push`** or any remote operations. This is local only.
3. After all commits are done, run `git log --oneline -n <N>` to show the committed results.

### Step 8 — Report

Report to the user:
- Number of commits created.
- Summary of each commit.
- Reminder that changes are local only and have not been pushed.

## Important Rules

- **NEVER commit secrets or credentials.** Always check first.
- **NEVER push to remote.** Local commits only.
- **NEVER proceed without user approval** on the commit plan.
- **NEVER run `git push`, `git push --force`, or any remote-affecting commands.**
