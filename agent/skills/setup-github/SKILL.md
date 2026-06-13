---
name: setup-github
description: Bootstrap a GitHub repo's branch model (main, develop, develop-auto) with protection rules using a given gh account
user_invocable: true
---

# Setup GitHub

When invoked, set up the standard branch model and protection rules for a GitHub repository.

## Inputs

This skill takes two arguments:

1. **`repo_url`** — the GitHub repository URL to configure (for example `https://github.com/owner/name`).
2. **`account`** — the `gh` account name to use for all GitHub operations against this repository.

If either argument is missing, ask the user for it before proceeding.

## Constraints

- Perform all GitHub operations with the `gh` CLI only, using the account given in `account`.
- If the `account` is not configured/authenticated or cannot be selected, **STOP** and ask the user how to proceed. Do not fall back to another account.
- Derive `owner` and `repo` from `repo_url`.

## Process

### Step 1 — Select the account and verify access

1. Switch the active `gh` account to `account` (for example `gh auth switch --user <account>`).
2. Confirm the account can access `owner/repo` (for example `gh repo view owner/repo`).
3. If access fails, STOP and ask the user.

### Step 2 — Create the branches

Ensure these three branches exist. Create any that are missing, basing each new branch on the current production history.

- **`main`** — production release branch.
- **`develop`** — active development branch (will become the default branch).
- **`develop-auto`** — branch for automated, unattended agent sessions.

Create branches via `gh` (for example using `gh api` to create the ref `refs/heads/<branch>` from the latest commit of `main`).

### Step 3 — Set the default branch and repository settings

1. Set `develop` as the repository's default branch (for example `gh repo edit owner/repo --default-branch develop`).
2. Enable automatic deletion of head branches when a pull request is merged, so merged feature branches are removed
   automatically (for example `gh repo edit owner/repo --delete-branch-on-merge`).
3. The repository must keep exactly three long-lived branches — `main`, `develop`, and `develop-auto`. Every other
   branch is a short-lived feature branch and is expected to be deleted automatically after its PR merges (per the
   setting above). Do not delete any of the three long-lived branches.

### Step 4 — Add the source-branch enforcement workflow

GitHub branch protection cannot natively restrict which source branch a pull request comes from. Because the
"PRs into `main` only from `develop`" rule MUST be enforced in GitHub (not just documented), this skill creates a
GitHub Actions workflow that fails any PR targeting `main` whose head branch is not `develop`, and registers it as a
required status check in Step 5.

1. Add a workflow file at `.github/workflows/pr-source-branch-guard.yml` with the following content:

   ```yaml
   name: pr-source-branch-guard
   on:
     pull_request:
       branches: [main]
   jobs:
     verify-source-branch:
       runs-on: ubuntu-latest
       steps:
         - name: Require PRs into main to come from develop
           run: |
             if [ "${{ github.head_ref }}" != "develop" ]; then
               echo "PRs into main must originate from 'develop' (got '${{ github.head_ref }}')."
               exit 1
             fi
             echo "Source branch '${{ github.head_ref }}' is allowed."
   ```

2. Commit this workflow into the repository **before** applying branch protection in Step 5, so the protected
   branches do not block its own creation. Commit it onto `main`, then bring `develop` and `develop-auto` up to date
   so the workflow exists on every long-lived branch.
3. The job name `verify-source-branch` is the status check that Step 5 marks as required on `main`.

### Step 5 — Apply branch protection

Apply protection to all three branches with these rules. Use `gh api` branch protection (a PUT to
`repos/owner/repo/branches/<branch>/protection`) or an equivalent repository ruleset, and actually set every rule in
GitHub — do not leave any rule as a documented-only convention.

- **`main`** — production release branch.
  - Protected: no direct pushes — require a pull request before merging.
  - No force pushes.
  - No branch deletion.
  - Require the `verify-source-branch` status check (from Step 4) to pass, which enforces that PRs into `main` come
    only from `develop`.
- **`develop`** — default and active development branch; contains the latest CI-passing code.
  - Protected: no direct pushes — require a pull request before merging.
  - No force pushes.
  - No branch deletion.
  - PRs into `develop` may come from any feature branch.
- **`develop-auto`** — branch for automated unattended agent sessions; treated like `develop`.
  - Protected: no direct pushes — require a pull request before merging.
  - No force pushes.
  - No branch deletion.
  - PRs into `develop-auto` may come from any feature branch.

### Step 6 — Verify and report

1. Re-read each branch's protection (for example `gh api repos/owner/repo/branches/<branch>/protection`) and confirm
   each configured rule is actually in effect in GitHub.
2. Report which branches were created vs. already present, the new default branch, the protection rules applied per
   branch, and that the `verify-source-branch` required check is active on `main`.
3. If anything blocked completion (especially the account check or insufficient permissions to set protection),
   report it clearly to the user.
