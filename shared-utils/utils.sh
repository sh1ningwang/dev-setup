#!/usr/bin/env bash
# shared-utils/utils.sh — Sourced by all install scripts
# Provides OS detection, logging, symlink helper, and common utilities

set -euo pipefail

# ── Repo root directory (derived from this script's location) ──
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Backup directory ──
BACKUP_BASE="$HOME/.shining-dev-setup-backup"

# ── Colors ──
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Logging ──

log_info() {
  printf "${GREEN}[INFO]${NC} %s\n" "$*"
}

log_warn() {
  printf "${YELLOW}[WARN]${NC} %s\n" "$*"
}

log_error() {
  printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

log_step() {
  printf "\n${BLUE}${BOLD}==> %s${NC}\n" "$*"
}

# ── OS Detection ──

detect_os() {
  if grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
    echo "wsl"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macos"
  else
    echo "linux"
  fi
}

# ── Windows Home (for WSL) ──

get_windows_home() {
  if [[ "$(detect_os)" != "wsl" ]]; then
    log_error "get_windows_home called on non-WSL system"
    return 1
  fi
  local win_user
  win_user="$(cmd.exe /C "echo %USERNAME%" 2>/dev/null | tr -d '\r')"
  echo "/mnt/c/Users/${win_user}"
}

# ── Command existence check ──

command_exists() {
  command -v "$1" &>/dev/null
}

# ── Symlink helper ──
# Usage: create_symlink <source> <target>
# - source: the file/dir in this repo (must exist)
# - target: where the symlink should be created
#
# Behavior:
# - If target is already a correct symlink → skip
# - If target exists (file/dir/wrong symlink) → back up then create symlink
# - Creates parent dirs as needed

create_symlink() {
  local src="$1"
  local target="$2"

  if [[ ! -e "$src" ]]; then
    log_error "Source does not exist: $src"
    return 1
  fi

  # If target is already a correct symlink, skip
  if [[ -L "$target" ]] && [[ "$(readlink "$target")" == "$src" ]]; then
    log_info "Already linked: $target → $src"
    return 0
  fi

  # If target exists (file, dir, or wrong symlink), back it up
  if [[ -e "$target" ]] || [[ -L "$target" ]]; then
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local backup_dir="${BACKUP_BASE}/${timestamp}"
    mkdir -p "$backup_dir"

    local target_name
    target_name="$(basename "$target")"
    mv "$target" "${backup_dir}/${target_name}"
    log_warn "Backed up existing $target → ${backup_dir}/${target_name}"
  fi

  # Create parent dirs if needed
  mkdir -p "$(dirname "$target")"

  ln -s "$src" "$target"
  log_info "Linked: $target → $src"
}
