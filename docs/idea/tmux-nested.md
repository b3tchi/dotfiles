# Nested Tmux Sessions for SSH

## Problem

When SSH-ing into remote machines that run tmux, you get tmux-inside-tmux.
Both layers respond to the same prefix key (C-b), and there's no visual
distinction between local and remote — leading to prefix conflicts and
confusion about which layer you're controlling.

The current setup already detects SSH sessions in `profile` (`SESSION_TYPE=remote/ssh`)
but nothing uses that variable to change tmux behavior.

## Constraints

- Mixed remotes: some have tmux (possibly these dotfiles), some don't
- Solution must work regardless of remote tmux configuration
- Both prefix conflict and visual confusion need solving

## Approaches

### 1. F12 Toggle + Visual Indicator (Recommended)

A single keybind (F12) toggles the outer (local) tmux "off" — disabling its
prefix and keybindings so all keys pass through to the inner (remote) tmux.
The status bar changes visually to show which layer is active.

**Mechanism:** Uses tmux `key-table` feature (`root` vs custom table). When
toggled, outer tmux switches to a key-table where only F12 is bound (to
toggle back). All other keys pass through to the inner session.

**Visual distinction:**
- Normal mode: current status bar style
- Passthrough mode: status bar changes color (e.g., red accent) with "REMOTE" indicator

**Trade-offs:**
- (+) Single key toggle, ergonomic for heavy remote work
- (+) Well-established pattern, lots of precedent
- (+) Works regardless of remote tmux config
- (-) Must remember to toggle; if you forget, prefix goes to outer

### 2. Different Prefix on Remote

Local tmux uses C-b, remote tmux uses C-a. Both layers always active with
distinct prefixes. Visual distinction via status bar color.

**Trade-offs:**
- (+) No toggling — both layers always accessible
- (+) Simple mental model: C-b = local, C-a = remote
- (-) Only works if you control the remote config
- (-) Need to remember two prefixes
- (-) Requires changes to remote tmux.conf on every machine

### 3. Smart Hybrid (Toggle + Bashrc Detection)

Combines F12 toggle with changes to bashrc/tmux-start so that when SSH-ing
into a remote with these dotfiles, tmux auto-start detects nesting and either
skips auto-start or uses a different prefix automatically. F12 toggle remains
for unmanaged remotes.

**Trade-offs:**
- (+) Best UX when both local and remote use these dotfiles
- (+) Gracefully degrades to toggle-only for unmanaged remotes
- (-) More moving parts — bash detection, tmux config, conditional logic
- (-) Higher complexity for marginal gain over approach 1 alone

## Phase 1: Remote Hostname in Title (Implemented)

**Approach:** `txs` (tmux-ssh) wrapper handles host-side awareness.

**Components:**
- `nushell/actions/tmux-ssh` — SSH wrapper that sets tmux pane option `@ssh_host`,
  renames window, cleans up on disconnect. Aliased as `txs` in nushell config.
- `tmux.conf` `set-titles-string` — uses `#{pane_current_path}@#{session_group}` for
  local, `[#{pane_title}]#{@ssh_host}@#{session_group}` for SSH panes (via `@ssh_host` conditional).
- `nushell/config.nu` `osc2: false` — nushell no longer sets terminal title, letting
  tmux's `set-titles` be the sole title setter for reliable nested propagation.

**Title format:**
- Local: `~/.dotfiles@dotfiles`
- SSH: `[~/.dotfiles@local]home@dotfiles` — [remote_path@remote_group]host@local_group

## Idea: WM Dynamic Title Stripping

When on a project workspace (e.g. `dotfiles_1`), the `@dotfiles` suffix in the
terminal title is redundant. A WM-level daemon could strip it dynamically.

**Mechanism:** Both i3 and sway support:
- IPC event subscription: `i3msg -t subscribe -m '["window"]'` — streams
  window title change events in real-time
- Per-window title rewriting: `i3msg '[con_id=X]' title_format "..."` — dynamically
  rewrites what the WM displays (using `%title` as placeholder for original title)

**Approach:** Background daemon (nushell script) that:
1. Subscribes to `window::title` events via `wm-ipc.nu` (WM-agnostic)
2. On title change, checks if window is on a project workspace
3. If `@project` suffix matches workspace project name, strips it via `title_format`

**Notes:**
- `wm-ipc.nu` already abstracts i3/sway IPC
- i3 config already uses `title_format`: `for_window [all] title_format "%title"` (line 197)
- Would run as part of i3/sway session startup

## Current State (for reference)

- `profile:50-57` — detects SSH via `SSH_CLIENT`/`SSH_TTY`, sets `SESSION_TYPE=remote/ssh` (unused)
- `distro/bashrc:18-41` — auto-starts tmux via `tmux-start` on every interactive shell
- `tmux/tmux.conf` — title passthrough via `pane_current_path`, `@ssh_host` conditional
- `nushell/actions/tmux-start` — session group management, no SSH awareness
- `nushell/actions/tmux-ssh` — SSH wrapper with tmux pane tagging
