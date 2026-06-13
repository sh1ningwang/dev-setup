# dev-setup

Personal dev environment config files, managed via a single `link` script that symlinks (or generates) configs to their expected paths.

## Repository Structure

Packages are grouped into category directories, with a few standalone packages at the root:

```
dev-setup/
├── agent/
│   ├── provider/
│   │   └── claude-code/      # Claude Code CLI — settings, skills, rules, ccstatusline
│   └── skills/               # vendored, self-contained skill packages (NOT linked)
│       ├── sa-design/        #   spec a context → GitHub issues (templates + consensus agents)
│       └── sa-implement/     #   autonomous issue→PR loop (bin/ lib/ agents/ templates/ references/)
├── git/
│   ├── config                # main git config → ~/.gitconfig
│   ├── personal.gitconfig    # personal profile (conditional include)
│   ├── work.gitconfig        # work profile (conditional include)
│   └── lazygit/              # lazygit TUI config
├── terminal/
│   ├── ghostty/              # Ghostty terminal emulator config
│   └── neovim/               # Neovim (LazyVim) config
├── flameshot/                # Screenshot tool config + autostart
├── rime/                     # Rime input method engine config
├── zed/                      # Zed editor settings + keymap
└── link                      # Symlink/generate manager script
```

The `link` script identifies packages by name (e.g. `claude-code`, `ghostty`); the category directories above are an organizational layer and do not change package names or their target paths. The `claude-code` package now lives at `agent/provider/claude-code/`.

`agent/skills/` holds **self-contained** skill packages vendored from [github.com/sh1ningwang/auto](https://github.com/sh1ningwang/auto) — each carries its own engine (`bin/`, `lib/`, `agents/`, `templates/`, `references/`) and resolves all paths from its own package root, so it depends on no external plugin install. These are **source only**: the `link` script does not symlink them anywhere.

## Quick Start

```bash
# Link all packages
./link

# Link specific packages only
./link claude-code ghostty

# Check link status
./link check

# Unlink all
./link unlink
```

## Components

| Package | Link Mode | Description |
|---------|-----------|-------------|
| [claude-code](#claude-code) | custom | Claude Code CLI — settings, skills, and rules |
| [flameshot](#flameshot) | custom | Screenshot tool — template-based config + autostart |
| [git](#git) | custom | Git config with conditional personal/work profiles |
| [ghostty](#ghostty) | file | Terminal emulator with Catppuccin Latte theme |
| [lazygit](#lazygit) | file | Git TUI with Catppuccin Latte colors and delta pager |
| [neovim](#neovim) | dir | Neovim with LazyVim and Catppuccin Latte colorscheme |
| [rime](#rime) | glob | Rime input method engine config (via fcitx5) |

---

### claude-code

Claude Code CLI settings, custom skills, and rules.

| Item | Target Path |
|------|-------------|
| `settings.json` | `~/.claude/settings.json` |
| `skills/` | `~/.claude/skills/` |
| `rules/` | `~/.claude/rules/` |

**Settings** — permission allowlist for core tools (Bash, Read, Write, Edit, etc.) and deny rules for destructive commands (`rm -rf /`, `git push --force`).

**Rules** — critical rules for model usage, agent team orchestration, and write access restrictions.

**Skills** (15 custom skills):

| Category | Skill | Description |
|----------|-------|-------------|
| Analysis | `analyze-functional-requirements` | Detailed functional requirements with epics and user stories |
| Architecture | `architect-technical-implementation` | High-level system, API, backend, and UI/UX design |
| Architecture | `architect-technical-testing` | Testing specification — unit, integration, regression, quality gates |
| Implementation | `implement-backend` | Backend code — interfaces, abstractions, test-driven development |
| Implementation | `implement-frontend` | Frontend code — UX-focused, clean modern UI |
| Debugging | `debug` | Root cause analysis — never concludes before 99% certainty |
| Review | `review-code-quality` | File size, decoupling, test coverage >80%, build verification |
| Review | `review-security-risk` | Security vulnerabilities in code and package versions |
| Review | `review-performance` | Performance bottlenecks under high concurrency |
| Review | `review-secrets-leaks` | Hardcoded secrets and credential leak detection (manual + gitleaks) |
| Review | `review-functional-requirements` | Verify implementation matches functional requirements 100% |
| Documentation | `write-documentation` | Code docs, spec docs — tables and diagrams |
| Workflow | `ralph` | 12-agent team: analyze → architect → implement → review → iterate |
| Workflow | `commit` | Smart git commit — secrets check, grouped commits, user approval |

---

### flameshot

Screenshot tool with template-based configuration and autostart support.

| Item | Target Path |
|------|-------------|
| `flameshot.ini` (generated) | `~/.config/flameshot/flameshot.ini` |
| `flameshot-autostart.desktop` | `~/.config/autostart/flameshot-autostart.desktop` (Linux) |
| `org.flameshot.Flameshot.plist` | `~/Library/LaunchAgents/org.flameshot.Flameshot.plist` (macOS) |

The config uses a `__SAVE_PATH__` template placeholder that gets replaced with `~/Pictures/screenshots` at link time — this avoids hardcoding machine-specific paths.

---

### git

Git config with `gh` credential helper and conditional profile includes.

| Item | Target Path |
|------|-------------|
| `config` | `~/.gitconfig` |
| `personal.gitconfig` | `~/.config/git/personal.gitconfig` |
| `work.gitconfig` | `~/.config/git/work.gitconfig` |

Profiles are loaded conditionally based on repo path:
- `~/code/personal/` → `personal.gitconfig`
- `~/code/work/` → `work.gitconfig`

---

### ghostty

Terminal emulator with Catppuccin Latte theme and JetBrains Mono Nerd Font.

| Item | Target Path |
|------|-------------|
| `config` | `~/.config/ghostty/config` (Linux) |
| `config` | `~/Library/Application Support/com.mitchellh.ghostty/config` (macOS) |

---

### lazygit

Git TUI with Catppuccin Latte color scheme, Nerd Font icons, and delta as the diff pager.

| Item | Target Path |
|------|-------------|
| `config.yml` | `~/.config/lazygit/config.yml` |

---

### neovim

Neovim with LazyVim starter config and Catppuccin Latte colorscheme.

| Item | Target Path |
|------|-------------|
| `terminal/neovim/` (dir) | `~/.config/nvim/` |

---

### rime

Rime input method engine config (via fcitx5). Luna Pinyin with custom settings.

| Item | Target Path |
|------|-------------|
| `*.yaml` | `~/.local/share/fcitx5/rime/` |

## Link Script

The `link` script supports three link modes:

| Mode | Behavior |
|------|----------|
| `file` | Symlink a single file |
| `dir` | Symlink an entire directory |
| `glob` | Symlink each matching file individually |
| `custom` | Package-specific logic (e.g., template generation, multi-target linking) |

Existing files are automatically backed up to `~/.config-backups/<package>/` before being replaced.

### Commands

```bash
./link              # Link all packages
./link <pkg> ...    # Link specific packages
./link check        # Show link status for all packages
./link unlink       # Remove all managed symlinks (restores backups)
```
