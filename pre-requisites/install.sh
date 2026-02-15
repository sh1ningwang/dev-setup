#!/usr/bin/env bash
# pre-requisites/install.sh — Install prerequisite tools needed by other components
# Run this before any other component's install script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared-utils/utils.sh"

OS="$(detect_os)"

# ── Install Homebrew ──

log_step "Checking Homebrew"

if ! command_exists brew; then
  log_info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add brew to PATH for the rest of this script
  if [[ "$OS" == "macos" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
else
  log_info "Homebrew already installed"
fi

# ── Prerequisite tools ──

TOOLS=(
  curl
  git
  gh
  node
  unzip
  ripgrep
  fd
  fzf
  wget
  jq
  tree
  git-delta
)

log_step "Installing prerequisite tools"

for tool in "${TOOLS[@]}"; do
  # Map brew package names to command names for checking
  local_cmd="$tool"
  case "$tool" in
    ripgrep)   local_cmd="rg" ;;
    fd)        local_cmd="fd" ;;
    git-delta) local_cmd="delta" ;;
    node)      local_cmd="node" ;;
  esac

  if command_exists "$local_cmd"; then
    log_info "$tool already installed"
  else
    log_info "Installing $tool..."
    brew install "$tool"
  fi
done

log_step "Pre-requisites complete"
