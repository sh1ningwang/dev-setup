---
name: refresh-instruction
description: Pull the canonical instruction rule files from the dev-setup repo and regenerate this agent's global instruction file
user_invocable: true
---

# Refresh Instruction

When invoked, regenerate this agent's global instruction file from the canonical rule files maintained in the `dev-setup` repository.

## Process

### Step 1 — Read the canonical instruction rules

1. Use `gh` with the account **`sh1ningwang`** to read the instruction rule files at:
   `https://github.com/sh1ningwang/dev-setup/tree/main/agent/instruction`
2. Read **every** instruction rule file under the `agent/instruction/` directory (for example `git.md`, `code.md`, `security.md`, `automation.md`, and any others present at refresh time).
3. If you **cannot** use the `gh` account `sh1ningwang` (it is not configured, not authenticated, or not switchable), **STOP** and report this to the user. Do not fall back to another account.

### Step 2 — Combine into one instruction document

1. Combine all of the instruction rule files into a **single markdown instruction file**.
2. Add proper markdown structure: a top-level title, one section per source rule file, and subsections where they aid clarity.
3. Preserve every rule from every source file — do not drop, weaken, or summarize away any rule.

### Step 3 — Write it as this agent's global configuration

1. Determine your own agent type (for example Claude Code, OpenCode, Codex, etc.).
2. Format the combined instruction file to fit your agent type's expected global instruction format and location.
3. Save it as the **global instruction file** for your agent type (e.g. `AGENTS.md` for OpenCode, `CLAUDE.md` for Claude Code).
4. If a global instruction file already exists for your agent type, you **may overwrite** it.
5. Ensure the generated file is valid and well-formed for your agent type.

### Step 4 — Report

1. Report which source files were combined and where the global instruction file was written.
2. If anything blocked completion (especially the `gh` account check in Step 1), report it clearly to the user.
