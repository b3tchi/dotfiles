# Project Workspace System

A stateless project management system that spans two layers: the **WM layer** (i3 or sway workspaces) and the **tmux layer** (session groups). Projects are registered in a single YAML file (`~/.config/project/projects.yaml`) containing only name-to-path mappings. All workspace and session state is derived at runtime.

## Architecture

```
 WM Layer (i3 / sway)              Terminal Layer (bash + tmux + nushell)
 ─────────────────────              ─────────────────────────────────────

 $mod+p / $mod+Shift+p            Terminal opens on project workspace
        │                                    │
 project-picker                       bashrc detects workspace name
        │                                    │
 rofi ── select project             WM IPC -t get_workspaces + grep/sed
        │                                    │
 WM IPC workspace <name>            Matches project pattern? ─── no ──> tmux-start attach 0 local
                                             │ yes
                                     export PROJECT=<name>
                                             │
                                     tmux-start attach 0 <name>
                                             │
                                     tmux session group = <name>
                                             │
                                     nushell starts (default shell)
                                             │
                                     export-env reads $env.PROJECT
                                             │
                                     cd to project path
```

## Data Store

```yaml
# ~/.config/project/projects.yaml
projects:
  dotfiles:
    path: /home/jan/.dotfiles       # local entry
  myapp:
    path: /home/jan/repos/myapp     # local entry
  remoteapp:
    path: /home/user/repos/remoteapp  # remote entry — path lives on the workstation
    ssh: workstation                  # ~/.ssh/config.d/workstation Host alias
```

No workspace assignments, no session state. Just name, path, and an optional ssh profile.

The `ssh` field is optional. When absent the entry is local (today's behavior). When present the entry is remote: `project go` delegates to `tmux-to-workstation` instead of doing a local `cd`. A mixed registry of local and remote entries is valid. `ssh: null` and `ssh: ""` are normalised to absent (treated as local).

## WM Layer (i3 + sway)

### WM Detection

The `wm-ipc.nu` module auto-detects whether i3 or sway is running and provides a unified `ipc` command. All workspace scripts use this abstraction, so the same scripts work on both window managers.

### Files

| File | Location (symlinked) | Purpose |
|------|---------------------|---------|
| `nushell/actions/wm-ipc.nu` | `~/.local/bin/wm-ipc.nu` | WM detection (i3/sway) + unified IPC |
| `nushell/actions/ws-list.nu` | `~/.local/bin/ws-list.nu` | Shared workspace utilities (sort, find, normalize) |
| `nushell/actions/ws-switch.nu` | `~/.local/bin/ws-switch.nu` | Switch/move by display index |
| `nushell/actions/project-picker` | `~/.local/bin/project-picker` | Rofi project picker |
| `i3/config` | `~/.i3/config` | i3 keybindings |
| `sway/config.d/default` | `~/.config/sway/config.d/default` | Sway keybindings |
| `i3/config.ini` | `~/.config/polybar/config.ini` | Polybar bar config (i3 module with `%name%`) |

### Workspace Naming Convention

- **Single workspace** for a project: bare name (`dotfiles`)
- **Multiple workspaces** for a project: numbered (`dotfiles_1`, `dotfiles_2`)
- **Non-project workspaces**: numeric (`1`, `2`, etc.)

When a second workspace is created for a project, the bare name is renamed to `_1` and the new one gets `_2`. When a numbered workspace is destroyed and only one remains, it is **normalized** back to the bare name. Normalization runs automatically on every workspace switch and move.

### Keybindings

Same on both i3 and sway:

| Keybinding | Action |
|---|---|
| `$mod+p` | Rofi picker: switch to project workspace (excludes current project) |
| `$mod+Shift+p` | Rofi picker: create new workspace for project (includes current) |
| `$mod+1` .. `$mod+8` | Switch to Nth workspace by display order |
| `$mod+Ctrl+1` .. `$mod+Ctrl+8` | Move focused container to Nth workspace |
| `$mod+Shift+1` .. `$mod+Shift+8` | Move container to Nth workspace and follow |

### wm-ipc.nu

Detects which WM is running (checks sway first, then i3) and provides:

- **`ipc-cmd`** - Returns `"swaymsg"` or `"i3-msg"` depending on running WM
- **`ipc`** - Runs the detected IPC command with given arguments

### ws-list.nu (shared module)

Provides workspace utilities used by `ws-switch.nu` and `project-picker`:

- **`sorted`** - All workspaces sorted in display order (by `num` ascending)
- **`focused`** - The currently focused workspace
- **`for-project <name>`** - Find workspaces matching `<name>` or `<name>_N`
- **`normalize <name>`** - If only one numbered workspace exists for a project, rename it to bare name
- **`project-name <ws_name>`** - Extract project name from workspace name (`dotfiles_1` -> `dotfiles`, `3` -> null)

### ws-switch.nu

Switches workspaces by display position (1-based index). Runs `normalize` for all registered projects before resolving the index, and again after move/follow actions.

- If already on the target workspace, does nothing (no back-and-forth toggle)
- After moving a container, normalizes to clean up orphaned `_N` names

### project-picker

Rofi-based project picker. Two modes:

**Switch mode** (`$mod+p`):
1. Normalizes orphaned workspace names
2. Shows all projects except the one on the current workspace
3. On selection: switches to existing workspace, or creates bare-named one

**New mode** (`$mod+Shift+p`):
1. Normalizes orphaned workspace names
2. Shows all projects including current
3. On selection: renames bare name to `_1` if needed, creates next `_N`

### Bar Integration

- **Polybar** (i3): `internal/i3` module displays workspace names with `%name%` tokens. `index-sort = true` sorts by `num`.
- **Waybar** (sway): `sway/workspaces` module displays workspace names with `{name}` format.

Both show project workspace names (`dotfiles`) and numeric ones (`1`).

## Tmux Layer

### Files

| File | Location (symlinked) | Purpose |
|------|---------------------|---------|
| `nushell/actions/tmux-start` | `~/.local/bin/tmux-start` | Create/attach tmux sessions |
| `nushell/actions/tmux-project` | `~/.local/bin/tmux-project` | fzf project picker inside tmux |
| `tmux/tmux.conf` | `~/.tmux.conf` | Tmux configuration |
| `distro/bashrc` | `~/.bashrc` | Shell startup with workspace detection |

### Shell Startup Chain

```
Terminal opens
    │
    v
bash (bashrc)
    │── Detects WM (sway or i3) via pgrep
    │── Gets workspace name via WM IPC
    │── Matches against project patterns:
    │     "dotfiles_1" -> PROJECT=dotfiles
    │     "dotfiles"   -> PROJECT=dotfiles (verified against projects.yaml)
    │     "3"          -> no project
    │── Runs: tmux-start attach 0 <PROJECT|local>
    │
    v
tmux (session group = PROJECT or "local")
    │── default-shell = nushell
    │── Session group name aligns with project name
    │── Status bar shows: window@session_group
    │
    v
nushell (config.nu loads project module)
    │── export-env checks $env.PROJECT
    │── If set: looks up path in projects.yaml, cd to project dir
    │── Project commands available: list, add, remove, go
```

### tmux-start

Creates or attaches to tmux sessions using session groups. The session name argument determines the group:

- `tmux-start attach 0 local` - Creates/attaches to `local_0`, `local_1`, etc.
- `tmux-start attach 0 dotfiles` - Creates/attaches to `dotfiles_0`, `dotfiles_1`, etc.

Each terminal gets its own session linked to the group, sharing windows.

### tmux-project (prefix+p)

fzf-based project picker accessible inside tmux via `prefix+p`. Shows registered projects with active session indicators. On selection, switches to existing session group or creates a new one.

### project go (nushell command)

Navigate to a project from the nushell command line:

```nushell
project go dotfiles    # cd + tmux session switch/create
```

When inside tmux, switches the client to the project's session group. When outside tmux, creates and attaches a new session.

## Nushell Project Module

### Commands

| Command | Description |
|---|---|
| `project list` | List registered projects with active tmux session indicators. Table includes `name`, `path`, `ssh` (empty for local, profile name for remote), and `active` columns. |
| `project add <name> [path]` | Register a local project (path defaults to current directory). |
| `project add <name> <path> --ssh <profile>` | Register a remote project. `path` is the directory on the remote host; `--ssh` is the `~/.ssh/config.d/<profile>` Host alias. `path` must be explicit — PWD default is not available for remote entries. |
| `project remove <name>` | Unregister a project |
| `project go <name>` | Navigate to project. Local: cd + tmux session management (unchanged). Remote: delegates to `tmux-to-workstation connect -g <name> --cwd <path> -- <ssh-alias>`; no local cd. |

### Auto-cd on Startup

When the `PROJECT` environment variable is set (by bashrc), nushell's `export-env` block automatically changes to the project directory. This happens transparently when opening a terminal on a project workspace.

Remote entries are silently skipped during auto-cd. Initiating an ssh connection on every shell open would be surprising and breaks offline; remote navigation is opt-in via explicit `project go`.

## Use Cases

### 1. Start working on a project

1. Press `$mod+p`
2. Select project from rofi list
3. WM switches to (or creates) the project workspace
4. Open a terminal (`$mod+Return`)
5. Terminal auto-detects workspace, tmux session group = project name, nushell cd's to project dir

### 2. Open a second workspace for the same project

1. Press `$mod+Shift+p`
2. Select the project (current project is shown)
3. Existing workspace renamed from `dotfiles` to `dotfiles_1`, new `dotfiles_2` created
4. Open terminals on either workspace - both share the same tmux session group

### 3. Switch between projects

1. Press `$mod+p` (current project is hidden from list)
2. Select another project
3. WM switches to that project's workspace
4. Or use `$mod+1`..`$mod+8` to switch by bar position

### 4. Move a window to another workspace

1. Press `$mod+Ctrl+N` to move without following
2. Press `$mod+Shift+N` to move and follow
3. If the source workspace becomes empty and is destroyed, the remaining project workspace normalizes back to bare name

### 5. Switch projects inside tmux (without WM)

1. Press tmux `prefix+p`
2. fzf picker shows projects with active session indicators
3. Select a project to switch tmux session group

### 6. Register a new project

```nushell
cd ~/repos/my-new-project
project add my-new-project
```

Or with explicit path:

```nushell
project add my-new-project ~/repos/my-new-project
```

### 6b. Register a remote project

Prerequisite: `~/.ssh/config.d/workstation` contains a `Host workstation` entry with the connection parameters (user, hostname, port).

```nushell
# Register remote project — path is on the workstation, not local
project add myapp /home/user/repos/myapp --ssh workstation

# List confirms ssh column is populated
project list
# name    path                      ssh           active
# ------  ------------------------  ------------  ------
# myapp   /home/user/repos/myapp    workstation

# Navigate — opens thin local tmux window connected to remote session
project go myapp
# Equivalent to: tmux-to-workstation connect -g myapp --cwd /home/user/repos/myapp -- workstation
```

`project go` on a remote entry does not `cd` locally — it delegates entirely to `tmux-to-workstation`. The remote tmux session starts with its default-directory set to the registered `path`.

If the connection drops, `tmux-to-workstation revive` respawns the ssh command in-place; the remote session state survives the disconnect.

### 7. Clean up

```nushell
project remove old-project
```

Tmux sessions and workspaces for the removed project are not affected (they continue to exist until closed manually).

## Design Principles

- **Stateless**: No workspace assignments or session mappings stored. Everything is derived from workspace names and the project registry.
- **Convention over configuration**: Workspace naming (`<project>`, `<project>_N`) encodes all relationship info.
- **Normalize automatically**: Orphaned `_N` names are cleaned up on every workspace operation.
- **Layers are independent**: The WM layer and tmux layer work together but don't depend on each other. You can use `project go` without a WM, or WM workspaces without tmux.
- **WM agnostic**: Same scripts work on i3 and sway via `wm-ipc.nu` abstraction.
- **Minimal schema**: `projects.yaml` stores `name -> { path, ssh? }`. Local entries carry only `path`; remote entries add `ssh` (a profile alias). No workspace assignments, no session state, no other metadata.
- **Remote is opt-in**: Auto-cd on shell startup silently skips remote entries. Firing ssh on every shell open is surprising and breaks offline. Remote navigation requires explicit `project go`.
- **Single remote-attach entry point**: `project go` on remote entries always delegates to `tmux-to-workstation connect`. ssh connection parameters stay in `~/.ssh/config.d/<profile>` — the registry stores only the alias.
- **Backwards-compatible widening**: Local entries are unchanged. The `ssh` field is additive; existing `project add` / `project go` / `project list` behavior is preserved exactly.
