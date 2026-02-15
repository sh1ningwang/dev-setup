#!/usr/bin/env bash
# neovim/install.sh — Install Neovim and deploy LazyVim config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared-utils/utils.sh"

log_step "Neovim setup"

# ── Ensure Homebrew is available ──

if ! command_exists brew; then
  log_error "Homebrew is required. Run pre-requisites/install.sh first."
  exit 1
fi

# ── Install Neovim ──

if command_exists nvim; then
  log_info "Neovim already installed"
else
  log_info "Installing Neovim..."
  brew install neovim
fi

# ── Symlink config ──

log_step "Linking Neovim config"

create_symlink "${SCRIPT_DIR}/config" "$HOME/.config/nvim"

# ── Sync plugins ──

log_step "Syncing plugins"

log_info "Running Lazy sync (headless)..."
nvim --headless "+Lazy! sync" +qa 2>/dev/null || log_warn "Lazy sync had warnings (this is normal on first run)"

log_step "Neovim setup complete"
