---
name: skill-fetch
description: Download all skills from the dev-setup repo into this agent's global skills folder, overwriting any existing same-named skills
user_invocable: true
---

# Skill Fetch

When invoked, sync this agent's global skills folder with the canonical skills maintained in the `dev-setup` repository.

## Process

### Step 1 — Read the canonical skills

1. Use `gh` with the account **`sh1ningwang`** to read the skills at:
   `https://github.com/sh1ningwang/dev-setup/tree/main/agent/skills`
2. Enumerate every skill directory under `agent/skills/`.
3. If you **cannot** find or use the `gh` account `sh1ningwang` (it is not configured, not authenticated, or not switchable), **STOP** and ask the user how to proceed. Do not fall back to another account.

### Step 2 — Determine the global skills folder

1. Determine your own agent type (for example Claude Code, OpenCode, Codex, etc.).
2. Resolve the correct global skills folder for that agent type, for example:
   - Claude Code: `~/.claude/skills/`
   - OpenCode: `~/.config/opencode/skills/`

### Step 3 — Download the skills

1. Download every skill under `agent/skills/` (the full directory contents of each skill, not just `SKILL.md`) into the global skills folder.
2. Place each skill in its own directory named after the skill, matching the source layout.
3. If a skill with the same name already exists locally, **always overwrite** it with the version from the repository.

### Step 4 — Report

1. Report which skills were downloaded and the global folder they were written to.
2. If anything blocked completion (especially the `gh` account check in Step 1), report it clearly to the user.
