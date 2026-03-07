# Two-Phase WM Workspace Restore — Full Spec

## Problem

`sway-restore` launches foot terminals with `sleep 1sec` between each, waits `2sec`, then diffs
tmux session lists to match terminals to saved windows. Fragile, timing-dependent, sway-only
(hardcodes `^swaymsg`).

## Solution

Two-phase restore: prepare tmux sessions first, then launch terminals that auto-claim them.
Works for both sway and i3 via `wm-ipc.nu`.

## Saved State Format (no changes)

`~/.cache/sway-state.json` produced by `sway-save-state`:
```json
{
  "workspaces": [
    {
      "name": "auctions",
      "terminals": [
        { "session": "auctions", "window": 0 },
        { "session": "auctions", "window": 4 }
      ]
    }
  ]
}
```

`session` = base group name (not `auctions_3`, just `auctions`).
`window` = tmux window index that was active in that terminal.

---

## File 1: `nushell/actions/tmux-start`

### Current attach-mode behavior (lines 68–124)

1. Compute next `view_nr` = `max(existing session numbers) + 1`
2. Create `session_<view_nr>` via `tmux new-session -d -t $session -s $new_session`
3. Create a new window in it
4. `tmux attach-session -t $pane_target`
5. `tmux set destroy-unattached`

Always creates a new session. Never reuses existing unattached ones.

### New attach-mode behavior

Insert before step 1: check for an **unattached session** in the target group.

```
tmux list-sessions -F "#{session_name} #{session_attached} #{session_group}"
→ find first row where group == $session AND attached == 0
```

If found → attach to it directly (skip create). The pre-created session from phase 1
already has the correct window selected.

If not found → fall through to existing logic (create new session as before).

### Detailed change

After the early-return checks (tmux available, not already in tmux, uid lookup), and
before the "Get existing session numbers" block at line 68, add:

```nushell
    # Prefer an existing unattached session in this group (enables restore phase 2)
    if $mode == "attach" {
        let unattached = (tmux list-sessions -F "#{session_name} #{session_attached} #{session_group}"
            | lines
            | where $it != ""
            | parse "{name} {attached} {group}"
            | where group == $session and attached == "0"
            | first -s)

        if ($unattached != null) {
            tmux attach-session -t $unattached.name
            tmux set destroy-unattached
            return
        }
    }
```

This goes at line 68, before the existing session-creation logic. The `first -s` (or
equivalent null-safe first) returns null if no unattached session exists.

### Race condition analysis

Multiple foot terminals launch on the same workspace near-simultaneously. Each runs
bashrc → `tmux-start attach`. The window between querying unattached sessions and
attaching is small (microseconds). Even if two claim the same session, tmux allows
multiple clients per session — not ideal but not broken. In practice, foot terminals
boot sequentially enough (bash init, nu invocation, wm-ipc query) that this doesn't
happen.

---

## File 2: `nushell/actions/sway-restore`

### Complete rewrite

```nushell
#!/usr/bin/env nu
# Restore WM workspaces + terminals from saved state
# Works for both sway and i3 via wm-ipc.nu
#
# Phase 1: Pre-create tmux sessions with correct windows selected
# Phase 2: Launch foot terminals that auto-claim sessions via bashrc

const wm_ipc = '~/.local/bin/wm-ipc.nu'
use $wm_ipc *

def main [] {
    let state_file = ("~/.cache/sway-state.json" | path expand)
    if not ($state_file | path exists) {
        print "No saved state found"
        return
    }

    let state = (open $state_file)
    let workspaces = ($state | get -o workspaces | default [])

    if ($workspaces | is-empty) {
        print "No workspaces to restore"
        return
    }

    if (tmux list-sessions | complete | get exit_code) != 0 {
        print "No tmux sessions running, skipping restore"
        return
    }

    # Disable cleanup hooks — prevents tmux-cleanup from killing
    # unattached pre-created sessions before foot terminals claim them
    tmux set-hook -gu client-detached
    tmux set-hook -gu after-select-window

    # ── Phase 1: Pre-create tmux sessions ──
    # For each saved terminal, create a grouped session and select
    # the saved window. These remain unattached until phase 2.

    mut total_terminals = 0

    for ws in $workspaces {
        let terminals = ($ws | get -o terminals | default [])

        for term in $terminals {
            let group = ($term | get -o session | default "")
            let window = ($term | get -o window | default null)
            if ($group | is-empty) or $window == null { continue }

            # Next view number for this group
            let sessions = (tmux list-sessions -F "#{session_name}"
                | lines
                | where $it =~ $"^($group)_")

            let view_nr = if ($sessions | is-empty) {
                0
            } else {
                $sessions
                | parse $"($group)_{number}"
                | get number
                | into int
                | math max
                | $in + 1
            }

            let new_session = $"($group)_($view_nr)"
            print $"  Prepare: ($new_session) → window ($window)"
            tmux new-session -d -t $group -s $new_session
            tmux select-window -t $"($new_session):($window)"

            $total_terminals = $total_terminals + 1
        }
    }

    # ── Phase 2: Launch foot terminals ──
    # Each foot → bashrc → tmux-start attach → finds unattached session → claims it

    for ws in $workspaces {
        let ws_name = ($ws | get -o name | default "")
        if ($ws_name | is-empty) { continue }

        let terminals = ($ws | get -o terminals | default [])
        let count = ($terminals | length)

        if $count == 0 {
            print $"  Launch: ($ws_name) (empty workspace, 1 terminal)"
            ipc $"workspace ($ws_name); exec foot"
            continue
        }

        print $"  Launch: ($ws_name) (($count) terminals)"
        for _term in $terminals {
            ipc $"workspace ($ws_name); exec foot"
        }
    }

    # ── Wait for terminals to claim sessions ──
    # Poll until pre-created sessions are attached (max 30s)
    if $total_terminals > 0 {
        mut waited = 0
        loop {
            let unattached = (tmux list-sessions -F "#{session_attached}"
                | lines
                | where $it == "0"
                | length)

            if $unattached == 0 or $waited >= 30 {
                if $waited >= 30 {
                    print "  Warning: timed out waiting for terminals to attach"
                }
                break
            }

            sleep 1sec
            $waited = $waited + 1
        }
    }

    # Re-enable cleanup hooks
    tmux set-hook -g client-detached 'run-shell "~/.local/bin/tmux-cleanup"'
    tmux set-hook -g after-select-window 'run-shell "~/.local/bin/tmux-cleanup"'

    # Return to first workspace
    let first_name = ($workspaces | first | get -o name | default "")
    if ($first_name | is-not-empty) {
        ipc $"workspace ($first_name)"
    }

    print "Restore complete"
}
```

### Key differences from current implementation

| Aspect | Old | New |
|--------|-----|-----|
| WM commands | `^swaymsg` (sway-only) | `ipc` from wm-ipc.nu (sway + i3) |
| Terminal matching | Diff session lists before/after | No matching — bashrc claims unattached sessions |
| Sleeps | `sleep 1sec` per terminal + `sleep 2sec` wait | No sleeps in main flow; poll-wait only for hook re-enable |
| Session creation | Done implicitly by bashrc/tmux-start | Explicit in phase 1 with correct window pre-selected |

---

## File 3: `distro/dot.yaml`

Remove line 24 (`actions/tmux-start: ~/.local/bin/tmux-start`) so the nushell version
from `nushell/dot.yaml` wins the symlink. Bashrc calls `tmux-start` as external command;
the `#!/usr/bin/env nu` shebang handles it.

After change, run `rotz link nushell --force` to update the symlink.

---

## All Files Involved

### Modified

| File | Path | Change |
|------|------|--------|
| tmux-start (nu) | `nushell/actions/tmux-start` | Add unattached-session check in attach mode |
| sway-restore | `nushell/actions/sway-restore` | Full rewrite: two-phase restore using `ipc` |
| distro dot.yaml | `distro/dot.yaml` | Remove tmux-start link (line 24) so nushell version wins |

### Dependencies (unchanged, required at runtime)

**Orchestration**

| File | Path | Role |
|------|------|------|
| sway-session.sh | `sway/wsl/sway-session.sh` | Orchestrator: starts sway, calls `sway-restore` on startup, runs `watch_state` loop calling `sway-save-state` every 5s |

**WM layer**

| File | Path | Role |
|------|------|------|
| sway config | `sway/config` | Entry point — includes `sway/config.d/*` |
| sway default config | `sway/config.d/default` | Keybindings, appearance, workspace bindings using `ws-switch.nu` and `project-picker` |
| sway wsl config | `sway/config.d/wsl` | WSL-specific: clipboard sync, xwayland disable, output keybinding |
| wm-ipc.nu | `nushell/actions/wm-ipc.nu` → `~/.local/bin/wm-ipc.nu` | WM abstraction — `ipc` and `ipc-cmd` detect sway/i3, used by restore, save, bashrc |

**Terminal + tmux layer**

| File | Path | Role |
|------|------|------|
| foot config | `foot/foot.ini` | Terminal emulator config (font, colors) — foot is the `$term` in sway config |
| bashrc | `distro/bashrc` → `~/.bashrc` | Auto-tmux: detects workspace via `wm-ipc.nu` → calls `tmux-start attach 0 <project>` |
| tmux.conf | `tmux/tmux.conf` | Registers cleanup hooks (`client-detached`, `after-select-window`), sets nushell as default shell, passes `SWAYSOCK`/`I3SOCK`/`WAYLAND_DISPLAY` env |
| tmux-cleanup | `nushell/actions/tmux-cleanup` → `~/.local/bin/tmux-cleanup` | Session cleanup — kills unattached sessions/panes, respects pinned. Hooks disabled/re-enabled during restore |
| tmux-start (bash) | `distro/actions/tmux-start` | Bash version — will be superseded by nushell version after dot.yaml change |

**State**

| File | Path | Role |
|------|------|------|
| sway-save-state | `nushell/actions/sway-save-state` → `~/.local/bin/sway-save-state` | Walks sway/i3 tree, matches foot PIDs to tmux clients via `/proc`, saves state |
| Saved state | `~/.cache/sway-state.json` | `{ workspaces: [{ name, terminals: [{ session, window }] }] }` |

**Project system** (how workspace→session mapping is resolved)

| File | Path | Role |
|------|------|------|
| projects.yaml | `~/.config/project/projects.yaml` | Name→path registry. Bashrc checks workspace names against this to set `$PROJECT` |
| project-picker | `nushell/actions/project-picker` → `~/.local/bin/project-picker` | Rofi-based picker to create/switch project workspaces |
| ws-switch.nu | `nushell/actions/ws-switch.nu` → `~/.local/bin/ws-switch.nu` | Workspace switching by display position |

**Rotz linking**

| File | Path | Role |
|------|------|------|
| sway dot.yaml | `sway/dot.yaml` | Links sway-restore and sway-save-state to `~/.local/bin/` |
| nushell dot.yaml | `nushell/dot.yaml` | Links tmux-start, tmux-cleanup, wm-ipc.nu, ws-switch.nu, project-picker to `~/.local/bin/` |
| distro dot.yaml | `distro/dot.yaml` | Links bashrc, tmux-cleanup. **tmux-start link to be removed** |

---

## Restore Flow Walkthrough

Saved state:
```json
{ "workspaces": [
    { "name": "1", "terminals": [{ "session": "local", "window": 2 }] },
    { "name": "dotfiles", "terminals": [
        { "session": "dotfiles", "window": 0 },
        { "session": "dotfiles", "window": 1 }
    ]},
    { "name": "auctions", "terminals": [
        { "session": "auctions", "window": 0 },
        { "session": "auctions", "window": 4 }
    ]}
]}
```

**Phase 1** creates:
1. `local_N` → select-window :2
2. `dotfiles_N` → select-window :0
3. `dotfiles_N+1` → select-window :1
4. `auctions_N` → select-window :0
5. `auctions_N+1` → select-window :4

All 5 sessions unattached, each on the correct window.

**Phase 2** launches:
1. `ipc "workspace 1; exec foot"` → bashrc detects ws "1" → `tmux-start attach 0 local`
   → finds unattached `local_N` → attaches → window 2 already selected ✓
2. `ipc "workspace dotfiles; exec foot"` → bashrc → `tmux-start attach 0 dotfiles`
   → finds unattached `dotfiles_N` → attaches → window 0 ✓
3. `ipc "workspace dotfiles; exec foot"` → bashrc → `tmux-start attach 0 dotfiles`
   → finds unattached `dotfiles_N+1` → attaches → window 1 ✓
4. `ipc "workspace auctions; exec foot"` → same pattern → window 0 ✓
5. `ipc "workspace auctions; exec foot"` → same pattern → window 4 ✓

---

## Verification

1. `rotz link nushell --force` → verify `ls -la ~/.local/bin/tmux-start` points to nushell version
2. Manual tmux-start test: create unattached session, run `tmux-start attach 0 <group>`, confirm it claims existing
3. `sway-save-state` → inspect `~/.cache/sway-state.json`
4. Kill all foot terminals or restart sway
5. `sway-restore` runs → verify correct workspaces, terminal counts, tmux windows
