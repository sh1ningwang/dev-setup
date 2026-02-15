#!/usr/bin/env bash
# wezterm/install.sh — Install WezTerm and deploy config
# macOS: installs via brew cask + symlinks config
# WSL: prints message to run install.ps1 from Windows PowerShell

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared-utils/utils.sh"

OS="$(detect_os)"

log_step "WezTerm setup"

if [[ "$OS" == "wsl" ]]; then
  log_warn "WezTerm is a GUI app — install it from Windows."
  log_info "Run from PowerShell: powershell.exe -File '${SCRIPT_DIR}/install.ps1'"
  exit 0
fi

if [[ "$OS" != "macos" ]]; then
  log_error "This install script supports macOS only. On WSL, use install.ps1."
  exit 1
fi

# ── Install WezTerm ──

if command_exists wezterm; then
  log_info "WezTerm already installed"
else
  log_info "Installing WezTerm..."
  brew install --cask wezterm
fi

# ── Install JetBrains Mono Nerd Font ──

log_step "Checking JetBrains Mono Nerd Font"

if brew list --cask font-jetbrains-mono-nerd-font &>/dev/null; then
  log_info "JetBrains Mono Nerd Font already installed"
else
  log_info "Installing JetBrains Mono Nerd Font..."
  brew install --cask font-jetbrains-mono-nerd-font
fi

# ── Symlink config ──

log_step "Linking WezTerm config"

create_symlink "${SCRIPT_DIR}/config/wezterm.lua" "$HOME/.wezterm.lua"

log_step "WezTerm setup complete"
