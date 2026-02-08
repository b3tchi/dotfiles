# Project Workspace System

A stateless project management system that spans two layers: the **WM layer** (i3 workspaces) and the **tmux layer** (session groups). Projects are registered in a single YAML file (`~/.config/project/projects.yaml`) containing only name-to-path mappings. All workspace and session state is derived at runtime.

## Architecture

```
 WM Layer (i3)                    Terminal Layer (bash + tmux + nushell)
 ─────────────                    ─────────────────────────────────────

 $mod+p / $mod+Shift+p            Terminal opens on project workspace
        │                                    │
 project-picker.nu                    bashrc detects workspace name
        │                                    │
 rofi ── select project             i3-msg -t get_workspaces + grep/sed
        │                                    │
 i3-msg workspace <name>            Matches project pattern? ─── no ──> tmux-start attach 0 local
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
    path: /home/jan/.dotfiles
  myapp:
    path: /home/jan/repos/myapp
```

No workspace assignments, no session state. Just name and path.

## WM Layer (i3)

### Files

| File | Location (symlinked) | Purpose |
|------|---------------------|---------|
| `i3/scripts/ws-list.nu` | `~/.config/polybar/scripts/ws-list.nu` | Shared workspace utilities (sort, find, normalize) |
| `i3/scripts/ws-switch.nu` | `~/.config/polybar/scripts/ws-switch.nu` | Switch/move by Polybar display index |
| `i3/scripts/project-picker.nu` | `~/.config/polybar/scripts/project-picker.nu` | Rofi project picker |
| `i3/config` | `~/.i3/config` | Keybindings |
| `i3/config.ini` | `~/.config/polybar/config.ini` | Polybar bar config (i3 module with `%name%`) |

### Workspace Naming Convention

- **Single workspace** for a project: bare name (`dotfiles`)
- **Multiple workspaces** for a project: numbered (`dotfiles_1`, `dotfiles_2`)
- **Non-project workspaces**: numeric (`1`, `2`, etc.)

When a second workspace is created for a project, the bare name is renamed to `_1` and the new one gets `_2`. When a numbered workspace is destroyed and only one remains, it is **normalized** back to the bare name. Normalization runs automatically on every workspace switch and move.

### Keybindings

| Keybinding | Action |
|---|---|
| `$mod+p` | Rofi picker: switch to project workspace (excludes current project) |
| `$mod+Shift+p` | Rofi picker: create new workspace for project (includes current) |
| `$mod+1` .. `$mod+8` | Switch to Nth workspace by Polybar display order |
| `$mod+Ctrl+1` .. `$mod+Ctrl+8` | Move focused container to Nth workspace |
| `$mod+Shift+1` .. `$mod+Shift+8` | Move container to Nth workspace and follow |

### ws-list.nu (shared module)

Provides workspace utilities used by `ws-switch.nu` and `project-picker.nu`:

- **`sorted`** - All i3 workspaces sorted in Polybar display order (by `num` ascending, preserving i3 creation order for equal `num`)
- **`focused`** - The currently focused workspace
- **`for-project <name>`** - Find workspaces matching `<name>` or `<name>_N`
- **`normalize <name>`** - If only one numbered workspace exists for a project, rename it to bare name
- **`project-name <ws_name>`** - Extract project name from workspace name (`dotfiles_1` -> `dotfiles`, `3` -> null)

### ws-switch.nu

Switches workspaces by Polybar display position (1-based index). Runs `normalize` for all registered projects before resolving the index, and again after move/follow actions.

- If already on the target workspace, does nothing (no back-and-forth toggle)
- After moving a container, normalizes to clean up orphaned `_N` names

### project-picker.nu

Rofi-based project picker. Two modes:

**Switch mode** (`$mod+p`):
1. Normalizes orphaned workspace names
2. Shows all projects except the one on the current workspace
3. On selection: switches to existing workspace, or creates bare-named one

**New mode** (`$mod+Shift+p`):
1. Normalizes orphaned workspace names
2. Shows all projects including current
3. On selection: renames bare name to `_1` if needed, creates next `_N`

### Polybar Integration

The Polybar `internal/i3` module displays workspace names with `%name%` tokens. The `index-sort = true` setting sorts by `num` (matching `ws-list.nu`'s sort). Project workspaces show their name (`dotfiles`), numeric ones show their number (`1`).

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
    │── Detects i3 workspace name via i3-msg
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
| `project list` | List registered projects with active tmux session indicators |
| `project add <name> [path]` | Register a project (defaults to current directory) |
| `project remove <name>` | Unregister a project |
| `project go <name>` | Navigate to project: cd + tmux session management |

### Auto-cd on Startup

When the `PROJECT` environment variable is set (by bashrc), nushell's `export-env` block automatically changes to the project directory. This happens transparently when opening a terminal on a project workspace.

## Use Cases

### 1. Start working on a project

1. Press `$mod+p`
2. Select project from rofi list
3. i3 switches to (or creates) the project workspace
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
3. i3 switches to that project's workspace
4. Or use `$mod+1`..`$mod+8` to switch by Polybar position

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

### 7. Clean up

```nushell
project remove old-project
```

Tmux sessions and i3 workspaces for the removed project are not affected (they continue to exist until closed manually).

## Design Principles

- **Stateless**: No workspace assignments or session mappings stored. Everything is derived from workspace names and the project registry.
- **Convention over configuration**: Workspace naming (`<project>`, `<project>_N`) encodes all relationship info.
- **Normalize automatically**: Orphaned `_N` names are cleaned up on every workspace operation.
- **Layers are independent**: The WM layer and tmux layer work together but don't depend on each other. You can use `project go` without i3, or i3 workspaces without tmux.
- **No schema bloat**: `projects.yaml` only stores `name -> path`. Everything else is runtime state.
