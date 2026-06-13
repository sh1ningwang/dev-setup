---
name: config-fetch
description: Fetch this agent's provider configuration from the dev-setup repo and install it as the local global config
user_invocable: true
---

# Config Fetch

When invoked, install this agent's global configuration from the canonical provider configs maintained in the `dev-setup` repository.

## Process

### Step 1 — Verify the account

1. Use `gh` with the account **`sh1ningwang`** for all GitHub operations.
2. If the `sh1ningwang` gh account cannot be found (not configured, not authenticated, or not switchable), **STOP** and ask the user how to proceed. Do not fall back to another account.

### Step 2 — Determine your agent type and its config mapping

1. Determine your own agent type (for example Claude Code, OpenCode, Codex, etc.).
2. Map it to the matching provider config under
   `https://github.com/sh1ningwang/dev-setup/tree/main/agent/provider`:
   - **Claude Code** → `claude-code/settings.json` → local global `settings.json`
   - **OpenCode** → `opencode/opencode.jsonc` → local global `opencode.jsonc`
   - (other agent types: use the correspondingly named directory + config file under `agent/provider/`)

### Step 3 — Fetch and install

1. Use the `sh1ningwang` gh account to fetch the corresponding provider config file from the repository.
2. Copy it to your agent type's **local global configuration** location, overwriting the existing global config file if one is present.
3. Ensure the installed file is valid for your agent type.

### Step 4 — Report

1. Report which provider config was fetched and the local global path it was written to.
2. If anything blocked completion (especially the `sh1ningwang` account check in Step 1), report it clearly to the user.
