# dev-setup

Cross-platform dev environment setup. Each component is self-contained — run individual install scripts as needed.

**Supported platforms:** macOS, WSL (Ubuntu), Linux

## Quick Start

```bash
# 1. Install prerequisites first
bash pre-requisites/install.sh

# 2. Then install any component you want
bash neovim/install.sh
bash lazygit/install.sh
bash wezterm/install.sh
bash claude-code/install.sh
```

## Components

### pre-requisites

Installs Homebrew and essential tools: curl, git, gh, node, unzip, ripgrep, fd, fzf, wget, jq, tree, delta.

```bash
bash pre-requisites/install.sh
```

Run this first — other components depend on Homebrew.

### wezterm

Terminal emulator with JetBrains Mono Nerd Font and Catppuccin Latte theme.

```bash
# macOS
bash wezterm/install.sh

# Windows (from PowerShell)
powershell -File wezterm/install.ps1
```

On WSL, the install script will remind you to run the PowerShell script from Windows instead.

### neovim

Neovim with LazyVim starter config and Catppuccin Latte colorscheme.

```bash
bash neovim/install.sh
```

Installs Neovim, symlinks the config to `~/.config/nvim`, and syncs plugins.

### lazygit

Git TUI with Nerd Font icons and light theme.

```bash
bash lazygit/install.sh
```

Symlinks config to `~/.config/lazygit/config.yml`.

### claude-code

Claude Code CLI settings.

```bash
bash claude-code/install.sh
```

Symlinks config to `~/.claude/settings.json`.

## How It Works

- **Idempotent**: Every script checks if tools are already installed and skips if so. Configs are always re-symlinked to ensure they're up to date.
- **Backups**: Existing configs are backed up to `~/.shining-dev-setup-backup/<timestamp>/` before being replaced.
- **Self-contained**: Each component folder has everything it needs. No top-level orchestrator.
- **Shared utilities**: All scripts source `shared-utils/utils.sh` for OS detection, logging, and symlink management.
