# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a cross-platform dotfiles repository for managing configuration files across Linux (including Termux/Android), WSL, and Windows environments. The repository uses a multi-tool approach for dotfile management and supports various shells, editors, and development tools.

## Dotfile Management Systems

This repository uses multiple dotfile management approaches:

### 1. Legacy Bash Script (`dtlf.sh`)
- Manual symlink creation script located at `dtlf.sh`
- Uses the `ml` function to create symlinks from `~/dotfiles/` to target locations
- **Do not use this approach for new configurations** - it's being phased out

### 2. Rotz (Primary System)
- Modern dotfile manager using YAML configuration files
- Each application directory contains a `dot.yaml` file defining:
  - Platform-specific configurations (`global`, `windows`, `linux`)
  - Symlinks to create
  - Installation commands to run
  - Templating support with Handlebars syntax for conditional logic
- Supports environment detection: `whoami.distro`, `whoami.platform`, `env.HOME`, etc.
- Configuration files:
  - `rotz/config.yaml` - Main rotz configuration
  - `rotz-test/dot.yaml` - Testing configuration
  - `distro/dot.yaml` - Distribution-specific package installations

### 3. Rotz Template Examples
```yaml
# Conditional linking based on environment
links:
  config.fish: |
    {{#if (eq env.HOME "/data/data/com.termux/files/home")}}
    ~/.config/fish/config.fish
    {{else}}
    ~/.config/fish/config.fish
    {{/if}}

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
```

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
