#!/usr/bin/env bash
# lazygit/install.sh — Install lazygit and deploy config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared-utils/utils.sh"

log_step "Lazygit setup"

# ── Ensure Homebrew is available ──

if ! command_exists brew; then
  log_error "Homebrew is required. Run pre-requisites/install.sh first."
  exit 1
fi

# ── Install lazygit ──

if command_exists lazygit; then
  log_info "lazygit already installed"
else
  log_info "Installing lazygit..."
  brew install lazygit
fi

# ── Symlink config (file, not dir) ──

log_step "Linking lazygit config"

create_symlink "${SCRIPT_DIR}/config/config.yml" "$HOME/.config/lazygit/config.yml"

log_step "Lazygit setup complete"
