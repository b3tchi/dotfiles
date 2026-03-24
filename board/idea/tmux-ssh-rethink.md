# Tmux SSH Connection Rethink

## Problem

Every SSH+tmux connection has two sides:
- **Fat side** — full tmux UI (keybinds, status bar, window management)
- **Thin side** — minimal tmux for persistence only (no UI, survives disconnects)

The current `tmux-ssh` (`txs`) hardcodes local=fat, remote=thin. But there are two real use cases:

| Scenario | Example | Fat (UI) | Thin (persistence) |
|---|---|---|---|
| Working FROM workstation | Workstation → Server | Local (workstation) | Remote (server) |
| Working TO workstation | Phone → Workstation, Workstation-A → Workstation-B | Remote (workstation) | Local (phone/other) |

## Design

### Two separate tools

`tmux-ssh` stays unchanged. Two new tools added alongside it:

#### `tmux-to-workstation`

Local is thin, remote is fat. Used when connecting to a machine where the real work happens.

| Subcommand | Args | Description |
|---|---|---|
| `connect` | `<host>` | Detach from local fat if attached. Start/reuse local thin tmux (`-L remote`). SSH into remote, attach to remote fat session (fzf picker if multiple). |
| `list` | — | List local thin sessions (no host needed) |
| `reconnect` | — | Reattach to a local thin session |
| `cleanup` | — | Kill unattached local thin sessions |

**Thin-local behavior:**
- No status bar, no prefix, no keybinds
- Window title suffixed with `[remote-name]` from pane env variable
- Stores connection metadata per window: host, session, port, remote PID
- Survives UI/WM crashes — thin tmux stays alive when terminal or WM dies
- On SSH drop: window stays alive, manual reconnect via `reconnect`
- Each thin window = one SSH connection to one remote fat session

#### `tmux-from-workstation`

Local is fat, remote is thin. Used when running processes on a remote server.

| Subcommand | Args | Description |
|---|---|---|
| `connect` | `<host>` | SSH into remote, start remote thin tmux (`-L remote`). Copies thin config to remote. |
| `list` | `<host>` | List remote thin sessions |
| `reconnect` | `<host>` | Reconnect to a detached remote thin session |
| `cleanup` | `<host>` | Kill unattached remote thin sessions |

**Thin-remote behavior:**
- Config copied to remote `/tmp/tmux-thin-remote.conf`
- No status bar, no prefix, no keybinds
- Process persistence only

### Thin configs

| Config | Used by | Location | Purpose |
|---|---|---|---|
| `tmux-thin-local.conf` | `tmux-to-workstation` | Local dotfiles (`tmux/`) | Persistence + title propagation via `[remote-name]` |
| `tmux-thin-remote.conf` | `tmux-from-workstation` | Copied to remote `/tmp/` | Persistence only |

Both are invisible (no status, no prefix, no keybinds). `tmux-thin-local.conf` adds window title logic reading remote name from env variable.

### Reconnection

- **UI crash** (terminal/WM dies): Thin tmux survives. Reattach with `tmux -L remote attach`.
- **SSH drop** (network interruption): Thin window stays alive with stored metadata. Manual reconnect.
- No auto-reconnect.

### File locations

```
nushell/actions/tmux-to-workstation    # new
nushell/actions/tmux-from-workstation  # new
tmux/tmux-thin-local.conf             # new
tmux/tmux-thin-remote.conf            # renamed from tmux-remote.conf
nushell/actions/tmux-ssh               # unchanged
tmux/tmux-remote.conf                  # unchanged (kept for tmux-ssh)
```

### Symmetry

Each tool manages its respective thin side:
- `tmux-to-workstation` list/cleanup/reconnect → operates on **local** thin
- `tmux-from-workstation` list/cleanup/reconnect → operates on **remote** thin

## Current state (for reference)

- `nushell/actions/tmux-ssh` — existing SSH wrapper, stays unchanged
- `tmux/tmux-remote.conf` — current thin config, stays unchanged (used by tmux-ssh)
- `tmux/tmux.conf` — fat config with remote session keybinds (prefix e/E/X)
- `distro/actions/tmux-start` — session creation, used by tmux-ssh for remote starts
- `docs/idea/tmux-nested.md` — prior design notes on nested tmux problem
