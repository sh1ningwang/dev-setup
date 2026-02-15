#!/usr/bin/env bash
# claude-code/install.sh — Deploy Claude Code config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared-utils/utils.sh"

log_step "Claude Code setup"

# ── Symlink config ──

create_symlink "${SCRIPT_DIR}/config/settings.json" "$HOME/.claude/settings.json"

log_step "Claude Code setup complete"
