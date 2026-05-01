# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a cross-platform dotfiles repository for managing configuration files across Linux (including Termux/Android), WSL, and Windows environments. The repository uses a multi-tool approach for dotfile management and supports various shells, editors, and development tools.

## Platform Model

The goal is a **single unified TUI/CLI experience** across all devices, with i3/sway as the WM layer where a graphical session is available.

### Architecture: Host + Nested Environments

Three device types follow a consistent pattern — a host platform with an optional nested Linux environment where the actual work happens:

```
Linux (native)      →  [Core UX runs directly]
Windows (host)      →  WSL Arch (nested)    →  [Core UX runs here]
Android (host)      →  Termux / proot Arch  →  [Core UX runs here]
```

### Layers

| Layer | What | Applies To |
|---|---|---|
| **Core UX** | bash → tmux → nushell (starship + carapace), neovim, yazi, lazygit, bat, ripgrep, fzf, fd, bottom | All Linux environments (native, WSL, proot Arch, Termux) |
| **WM** | i3 or Sway — provides graphical session when available | See table below |
| **Host bridge** | Configs for the host OS that wraps a nested Linux env | Windows-native tools (WezTerm, pwsh, powertoys), Termux bootstrap, xdg-open/auth bridge |
| **Distro packages** | Package manager differences (pacman vs pamac vs pkg) | Minor variations between Arch, Manjaro, Arch ARM, Termux |

### WM per Platform

| Platform | Display Server | WM | Notes |
|---|---|---|---|
| Native Linux | X11 | i3 | Primary personal setup |
| WSL | WSLg (Wayland) | Sway | Wayland is what WSLg provides |
| Android + proot | Termux:X11 | i3 | X11 via Termux:X11 app |
| Android (terminal) | none | — | tmux only, no WM |

### Platform Inventory

| Platform | Role | Distro | Core UX | WM | Host Bridge |
|---|---|---|---|---|---|
| **Personal Linux** | native | Arch / Manjaro | yes | i3 (X11) | — |
| **WSL** | nested in Windows | Arch | yes | Sway (WSLg) | Windows-side: WezTerm, pwsh, powertoys, xdg-open bridge, auth/browser |
| **proot Arch** | nested in Termux | Arch | yes | i3 (Termux:X11) | Termux bootstrap scripts |
| **Termux** | direct on Android | — (pkg) | yes | — | Termux-specific paths, pkg installs |

### Detection Methods (Current State)

Platform detection is currently **inconsistent** across layers. Each config layer uses its own mechanism:

| Layer | Mechanism | Variables |
|---|---|---|
| Bash (`profile`) | `uname`, file existence checks | `IS_LINUX`, `IS_ANDROID`, `IS_WSL` |
| Rotz (`dot.yaml`) | Handlebars templates | `whoami.distro`, `whoami.platform`, `env.HOME`, `env.WSL_DISTRO_NAME` |
| Nushell | `$nu.os-info` | `.name`, `.kernel_version` |
| Tmux | shell conditionals | `$TERMUX_VERSION` |
| WezTerm (Lua) | `wezterm.target_triple` | — |

### Known Issues

1. **`profile`**: `[ -n $IS_WSL ]` missing quotes — Docker start runs on all platforms, not just WSL
2. **`dtlf.sh`**: Firefox linking uses `md` instead of `ml` (typo, broken)
3. **Termux detection**: 5 different methods across files (`env.HOME` check, `$TERMUX_VERSION`, dir check, `system-type`, `uname -o`)
4. **WSL detection**: 4 different methods (`wsl.exe` file check, kernel version regex, `WSL_DISTRO_NAME`, `wezterm.target_triple`)
5. **dtlf.sh ↔ Rotz overlap**: Some apps managed by both systems (wezterm, etc.)
6. **Missing rotz coverage**: Ubuntu has no dot.yaml integration

## Rotz — OS Setup Engine

Rotz is the **core mechanism** that bootstraps and configures the entire environment. It is the entry point on any fresh system: install rotz (`install-rotz.sh`), clone dotfiles, run `rotz install` / `rotz link` — and the platform model above is realized.

### How It Works

Each application directory contains a `dot.yaml` file that declares:
- **Links** — symlinks from the dotfiles repo to their target locations
- **Installs** — shell commands to install the application
- **Platform sections** — `global:`, `windows:`, `linux:` top-level keys handled natively by Rotz
- **Handlebars templates** — conditional logic within sections for distro/environment branching

### Platform Branching in Rotz

Rotz handles the platform model at two levels:

1. **Native platform sections** (`windows:` / `linux:`) — separates host-bridge configs (Windows-side tools) from Core UX configs (Linux-side)
2. **Handlebars conditionals** within `linux:` — handles distro and environment variations:
   - `{{#if (eq whoami.distro "Manjaro Linux")}}` — Manjaro-specific packages (pamac/AUR)
   - `{{#if (eq whoami.distro "Arch Linux")}}` — Arch-specific packages (pacman/yay)
   - `{{#if (eq whoami.distro "Arch Linux ARM")}}` — ARM-specific packages
   - `{{#if (eq env.HOME "/data/data/com.termux/files/home")}}` — Termux-specific paths
   - `{{#if env.WSL_DISTRO_NAME}}` — WSL-specific configs

### Available Template Variables

| Variable | Example Values | Use For |
|---|---|---|
| `whoami.distro` | `"Manjaro Linux"`, `"Arch Linux"`, `"Arch Linux ARM"` | Distro-specific package managers |
| `whoami.platform` | `"Linux"`, `"Windows"` | OS-level branching (rarely needed, use sections instead) |
| `env.HOME` | `/home/jan`, `/data/data/com.termux/files/home` | Termux detection |
| `env.WSL_DISTRO_NAME` | `"arch"`, unset | WSL detection |
| `whoami.username` | `"jan"` | User-specific paths |
| `whoami.arch` | `"x86_64"`, `"aarch64"` | Architecture-specific installs |

### Key Files

- `rotz/config.yaml` — Main rotz configuration
- `install-rotz.sh` — Bootstrap script (downloads rotz binary, handles arch/OS detection)
- `distro/dot.yaml` — Core distro-level package installations
- `rotz-test/dot.yaml` — Testing configuration

### Rotz Template Examples
```yaml
# Platform-specific installations
windows:
  installs:
    cmd: scoop install yazi bottom gh lazygit bat ripgrep

linux:
  installs:
    cmd: |
      {{#if (eq whoami.distro "Arch Linux")}}
      sudo pacman -Syu --needed --noconfirm yazi bottom git
      {{/if}}
      {{#if (eq whoami.distro "Manjaro Linux")}}
      sudo pacman -Syu --needed --noconfirm yazi bottom git
      pamac install lazygit-bin
      {{/if}}

# Conditional linking for Termux vs standard Linux
links:
  config.nu: |
    {{#if (eq env.HOME "/data/data/com.termux/files/home")}}
    ~/.config/nushell/config.nu
    {{else}}
    ~/.config/nushell/config.nu
    {{/if}}
```

### Meta-Packages

Environment-level meta-packages use rotz `depends` to pull in the right set of apps per target environment. Each is a `dot.yaml` with only `depends:` — no links or installs of its own.

| Meta-Package | Target | Depends On |
|---|---|---|
| `meta-linux` | Personal Linux (native, i3/X11) | distro, nushell, tmux, nvim, lazygit, claude, opencode, wezterm, kitty, i3, xterm, emacs, logseq, freecad, evolution, xournalpp |
| `meta-wsl` | WSL (nested in Windows, Sway/WSLg) | distro, nushell, tmux, nvim, lazygit, claude, opencode, sway |
| `meta-proot` | proot Arch (nested in Termux, i3/Termux:X11) | distro, nushell, tmux, nvim, lazygit, claude, opencode, i3 |
| `meta-termux` | Termux (direct on Android, no WM) | nushell, tmux, nvim, lazygit, claude, opencode |
| `meta-windows` | Windows host (bridge for WSL) | wezterm, winterm, pwsh, powertoys, fancywm, flow-launcher, office |

Usage: `rotz install meta-linux`, `rotz install meta-wsl`, etc.

Note: On a Windows + WSL setup, run `rotz install meta-windows` on the Windows side and `rotz install meta-wsl` inside WSL.

### Legacy: `dtlf.sh`

Manual symlink script being phased out. Some apps (gitconfig, tigrc, fish, code, kde) are still only managed here. **Do not use for new configurations** — migrate to `dot.yaml` instead.

## Shell Configurations

### Nushell (Primary Shell)
- Main config: `nushell/config.nu`
- Environment: `nushell/env.nu`
- Application integrations:
  - `nushell/apps/carapace.nu` - Completion engine
  - `nushell/apps/starship.nu` - Prompt
  - `nushell/apps/yazi.nu` - File manager
- Custom scripts in `nushell/scripts/`
- **Git Workflow Tool (`gwt`)**: Located at `nushell/scripts/gwt/mod.nu`
  - Manages git repositories using bare repo + worktree pattern
  - Commands:
    - `gwt repo init` - Create bare repo with worktrees
    - `gwt repo get <profile> <name>` - Clone from GitHub
    - `gwt repo push <profile> <scope>` - Create and push to GitHub
    - `gwt branch create <name> <from>` - Create new worktree branch
    - `gwt branch link <name>` - Link existing remote branch
    - `gwt branch remove <name>` - Remove worktree
    - `gwt branch version` - Semantic versioning for monorepos
    - `gwt user register <profile>` - Configure SSH keys
  - Uses profiles defined in `gwt data` function for multi-account management

### Bash
- Profile: `profile` - Environment setup, PATH configuration, platform detection
- Config: `distro/bashrc` - Main bashrc with tmux integration
- Logout: `bash_logout`
- **Auto-tmux session management**:
  - `start_local_session()` - Automatically starts/attaches to tmux on shell start
  - Creates numbered sessions: `local_0`, `local_1`, etc.
  - Each session gets its own window, auto-destroys when unattached
  - `kill_local_unattached()` - Cleanup function for detached windows (logs to `~/.tmux.log`)

### Other Shells
- Fish: `fish/config.fish` - Vi mode, PyEnv integration, NNN file manager
- Zsh: Configuration in `zsh/` directory (legacy)

## Terminal & Multiplexer

### Tmux
- Config: `tmux/tmux.conf`
- **Layered Shell Architecture**:
  - **Bash** - System default shell (for compatibility; nushell not fully mature yet)
  - **Tmux lifecycle** - Managed at bash system layer via `distro/bashrc`
  - **Nushell** - Runs inside tmux for all actual work and customizations
  - Platform-specific nushell paths:
    - Termux: `/data/data/com.termux/files/usr/bin/nu`
    - Other Linux: `/usr/sbin/nu`
- Vi mode keybindings (`mode-keys vi`)
- Mouse support enabled
- 10,000 line scrollback history
- Minimal status bar: Shows session name and window info on left, nothing on right
- Window titles: Format `#S[#W]` (session[window])
- Keybindings:
  - `r` - Reload config
- Available themes in `tmux/themes/` (not currently sourced):
  - `tokionight.conf` - TokyoNight color scheme
  - `gruvbox.conf` - Gruvbox color scheme

### Terminal Emulators
- WezTerm: `wezterm/wezterm.lua`
- Windows Terminal: `winterm/`

## Neovim Configuration

### Structure
- Entry point: `nvim/init.lua` (bootstraps Lazy.nvim)
- Config files in `nvim/config/`:
  - `lazy.lua` - LazyVim setup with language/plugin imports
  - `options.lua` - Vim options
  - `keymaps.lua` - Key mappings
  - `autocmds.lua` - Autocommands
- Plugin overrides in `nvim/plugins/` (30+ files)
- Uses LazyVim as base with extensive customization

### Language Support (via LazyVim extras)
- TypeScript, JSON, Go, Nushell, Markdown, YAML, Git
- Custom language configs:
  - `nvim/plugins/lang-go.lua`
  - `nvim/plugins/lang-pwsh.lua`
  - `nvim/plugins/lang-md.lua`

### Notable Plugin Customizations
- `nvim/plugins/gp.lua` - AI integration (7370 lines)
- `nvim/plugins/hydra.lua` - Custom key chords
- `nvim/plugins/neo-tree.lua` - File explorer
- `nvim/plugins/incline.lua` - Floating statuslines

## Environment Detection

The `profile` file sets environment variables for cross-platform compatibility:
- `IS_LINUX` - Linux detection
- `IS_ANDROID` - Termux/Android detection
- `IS_WSL` - WSL detection
- `THEME` - Global theme (tokionight/gruvbox)
- `REPOS_PATH` - Repository root (`$HOME/repos`)
- `MPXR_CONFIG_PATH` - Multiplexer config path

Platform-specific logic:
- WSL: Auto-starts Docker service
- Shared shell configs loaded from `~/.shell_config/shared/`
- Conditional PATH additions for Rust, Go, .NET, MSSQL tools

## Window Manager Configurations

- **i3**: `i3/` with scripts in `i3/scripts/` (Nushell-based for disk/RAM stats)
- **KDE Plasma**: `kde/` - Konsole, KWin rules, shortcuts, themes
- **Sway**: `sway/` - Wayland compositor
- **Qtile**: `qtile/` - Python-based WM
- **Windows PowerToys**: `powertoys/` - 20+ module configs

## Development Tools

### Git
- Config: `gitconfig`
- Uses delta pager with custom decorations
- Difftastic as diff tool
- Vi-based diff/merge tools
- Tig config: `tigrc`

### VS Code
- Settings: `code/settings.json`
- Keybindings: `code/keybindings.json`

### Scripts
- Ubuntu post-install scripts: `scripts/ubuntu/ubuntu-core-postinstall.sh`
- Individual tool installers in `scripts/ubuntu/`

## Installation Scripts

Distribution-specific package installations are defined in `distro/dot.yaml`:
- **Windows**: Scoop-based (`scoop install yazi bottom gh lazygit bat ripgrep wezterm`)
- **Arch/Manjaro**: Pacman-based with AUR support
- **Ubuntu**: Manual scripts in `scripts/ubuntu/`

Core tools across all platforms:
- yazi (file manager)
- bottom (system monitor)
- lazygit (git TUI)
- bat, ripgrep, fd, fzf (CLI utilities)
- wezterm (terminal)
- Iosevka Nerd Font

## Workflow Patterns

### Git Repository Management (gwt)
This dotfiles repo encourages a bare repo + worktree workflow:
1. Bare repo stored in `default/` directory
2. Each branch gets its own directory as a worktree
3. SSH config managed per-profile in `~/.ssh/config.d/`
4. Supports multi-user GitHub accounts with SSH key management

### Theme Management
- Global theme variable: `THEME=tokionight` (or gruvbox)
- Theme files in respective app directories:
  - `tmux/themes/`
  - `fzf/themes/`
  - `bat/themes/`
- Neovim uses LazyVim's colorscheme system

### Cross-Platform Compatibility
- Use Handlebars templates in `dot.yaml` files for conditional logic
- Test environment variables: `IS_WSL`, `IS_ANDROID`, `IS_LINUX`
- Path handling: Windows uses backslashes in gwt branch names
- Home directory detection: `$env.HOME` vs `$env.USERPROFILE`

## Key Directories Not to Modify

- `nvim.bckp/` - Backup of old Neovim config
- `nix-config.bckp/` - Backup of Nix configuration
- `rotz-test/` - Testing area for rotz configurations

## Directories to Ignore

- `archive/` - Archived/deprecated configurations. **Do not reference, modify, or include in searches unless explicitly mentioned by the user.**

## Adding New Configurations

1. Create `dot.yaml` in the application directory
2. Define platform-specific sections: `global`, `windows`, `linux`
3. Specify `links` with Handlebars conditionals if needed
4. Add `installs.cmd` for installation commands
5. Test with rotz before committing

## Notes

- PowerShell profile is synced to OneDrive for work integration (see `dtlf.sh:113-114`)
- Carapace completions cached in `~/.cache/carapace/init.nu`
- Nushell history: 100k max, plaintext format, shared across sessions
- SSH config uses include pattern for modular per-user configs


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
