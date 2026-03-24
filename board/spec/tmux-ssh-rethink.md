# Tmux SSH Two-Mode Fat/Thin Implementation Plan

> **For Claude:** Use infinifu:plan-executing, infinifu:plan-subagent, or infinifu:plan-scrum-master to implement this plan.

**Goal:** Add two new tools (`tmux-to-workstation`, `tmux-from-workstation`) that handle SSH+tmux connections with explicit fat/thin side selection, alongside the existing `tmux-ssh`.

**Architecture:** Each tool is a standalone nushell script in `nushell/actions/`, symlinked to `~/.local/bin/` via rotz. Each has a dedicated thin tmux config. Shared SSH-arg parsing helpers are reused from the existing `tmux-ssh` pattern (copied, not imported — nushell scripts are standalone). The local thin tmux uses socket `-L thin` to avoid colliding with the existing `-L remote` used by `tmux-ssh`.

**Tech Stack:** Nushell scripts, tmux, SSH, rotz (dot.yaml linking)

---

### Task 1: Create `tmux-thin-local.conf`

Thin tmux config for local side when using `tmux-to-workstation`. No UI, just persistence + title.

**Files:**
- Create: `tmux/tmux-thin-local.conf`

**Done when:** File exists, tmux can load it without errors, title shows `[remote-name]` when `@remote_name` is set and falls back gracefully when unset.

**Step 1: Write the config file**

```conf
# Thin-local tmux config for to-workstation connections (socket: thin)
# No UI — persistence + window title only

if-shell '[ -n "$TERMUX_VERSION" ]' {
  set-option -g default-shell /data/data/com.termux/files/usr/bin/nu
} {
  set-option -g default-shell /usr/sbin/nu
}

set -g status off
set -g prefix None
unbind-key -a
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:RGB"
set-option -sa terminal-overrides ",xterm*:Tc"
set -g history-limit 10000
set -g mouse on
set -g set-clipboard on
set -g allow-passthrough all

# Keep pane alive after SSH exits so we can see disconnection and reconnect
set -g remain-on-exit on

# Title propagation: show [remote-name] for WM title bars
# Falls back to "thin" when @remote_name is not set
set -g set-titles on
set -g set-titles-string "#{?@remote_name,[#{@remote_name}],thin}"
```

Note: `remain-on-exit on` is critical — when SSH drops, the pane stays alive (marked dead) instead of being destroyed. This enables the `cleanup` subcommand in `tmux-to-workstation` to find and kill dead windows via `#{pane_dead}`.

**Step 2: Verify config syntax**

Run: `tmux -L test-thin-local -f tmux/tmux-thin-local.conf start-server \; kill-server`
Expected: no errors, exit code 0

**Step 3: Commit**

```bash
git add tmux/tmux-thin-local.conf
git commit -m "feat: add tmux-thin-local.conf for to-workstation connections"
```

---

### Task 2: Create `tmux-thin-remote.conf`

Thin tmux config for remote side when using `tmux-from-workstation`. Process persistence only.

**Files:**
- Create: `tmux/tmux-thin-remote.conf`

**Done when:** File exists, tmux can load it without errors.

**Step 1: Write the config file**

```conf
# Thin-remote tmux config for from-workstation connections (socket: thin)
# No UI — process persistence only

if-shell '[ -n "$TERMUX_VERSION" ]' {
  set-option -g default-shell /data/data/com.termux/files/usr/bin/nu
} {
  set-option -g default-shell /usr/sbin/nu
}

set -g status off
set -g prefix None
unbind-key -a
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:RGB"
set-option -sa terminal-overrides ",xterm*:Tc"
set -g history-limit 10000
set -g mouse on
set -g set-clipboard on
set -g allow-passthrough all
```

**Step 2: Verify config syntax**

Run: `tmux -L test-thin-remote -f tmux/tmux-thin-remote.conf start-server \; kill-server`
Expected: no errors, exit code 0

**Step 3: Commit**

```bash
git add tmux/tmux-thin-remote.conf
git commit -m "feat: add tmux-thin-remote.conf for from-workstation connections"
```

---

### Task 3: Create `tmux-from-workstation` script

Local is fat, remote is thin. Manages remote thin sessions. Subcommands: `connect`, `list`, `reconnect`, `cleanup`.

**Files:**
- Create: `nushell/actions/tmux-from-workstation`

**Done when:** Script runs (`nu nushell/actions/tmux-from-workstation` prints help), all four subcommands parse without syntax errors.

**Step 1: Write the script**

The script reuses the SSH arg parsing pattern from `tmux-ssh` (see `nushell/actions/tmux-ssh:8-43` for `parse-hostname`, `scp-port-args`, `get-port`).

```nu
#!/usr/bin/env nu
# tmux-from-workstation: local fat, remote thin
# Manage remote thin tmux sessions for process persistence
# Symlinked to ~/.local/bin/tmux-from-workstation via rotz

# Extract hostname from SSH args (same pattern as tmux-ssh)
def parse-hostname [args: list<string>]: nothing -> string {
    $args
        | reduce --fold { skip: false, host: null } {|arg, acc|
            if $acc.skip {
                { skip: false, host: $acc.host }
            } else if ($arg | str starts-with "-") {
                let value_flags = ["-p" "-l" "-i" "-o" "-F" "-J" "-L" "-R" "-D" "-W" "-E" "-S" "-b" "-c" "-e" "-m" "-O" "-Q" "-w" "-B"]
                if ($arg in $value_flags) {
                    { skip: true, host: $acc.host }
                } else {
                    { skip: false, host: $acc.host }
                }
            } else if ($acc.host == null) {
                { skip: false, host: $arg }
            } else {
                $acc
            }
        }
        | get host
}

# Extract scp port args from ssh args
def scp-port-args [args: list<string>]: nothing -> list<string> {
    if ($args | any {|a| $a == "-p"}) {
        let port_idx = ($args | enumerate | where {|e| $e.item == "-p"} | first | get index)
        [-P ($args | get ($port_idx + 1))]
    } else { [] }
}

# Extract port value from ssh args
def get-port [args: list<string>]: nothing -> string {
    if ($args | any {|a| $a == "-p"}) {
        let port_idx = ($args | enumerate | where {|e| $e.item == "-p"} | first | get index)
        $args | get ($port_idx + 1)
    } else { "" }
}

def --wrapped "main connect" [
    ...args: string       # SSH args (e.g. -p 8022 user@host)
] {
    if ($args | is-empty) {
        main
        return
    }

    let hostname = parse-hostname $args

    if ($hostname == null) {
        print "Error: could not determine hostname from args"
        return
    }

    let display_host = if ($hostname | str contains "@") {
        $hostname | split row "@" | last
    } else {
        $hostname
    }

    let in_tmux = ($env | get -o TMUX | is-not-empty)

    if not $in_tmux {
        print "Error: must be inside a tmux session (local fat side)"
        return
    }

    # Copy thin config to remote
    let config_path = ($env.HOME | path join ".dotfiles/tmux/tmux-thin-remote.conf")
    let scp_result = (do { ^scp -q ...(scp-port-args $args) $config_path $"($hostname):/tmp/tmux-thin-remote.conf" } | complete)
    if $scp_result.exit_code != 0 {
        print $"Error: failed to copy thin config to ($hostname)"
        return
    }

    # Session name: displayhost_windowindex
    let window_index = (tmux display-message -p '#{window_index}' | str trim)
    let remote_session = $"($display_host)_($window_index)"

    # Store connection metadata on pane
    tmux set-option -p @thin_remote_host $hostname
    tmux set-option -p @thin_remote_session $remote_session
    tmux set-option -p @thin_remote_port (get-port $args)

    try {
        ^ssh -t ...$args $"bash -l -c 'tmux -L thin -f /tmp/tmux-thin-remote.conf new-session -A -s ($remote_session)'"
    } catch {
        print $"Error: failed to connect to ($hostname)"
    }

    # Check if session still exists after disconnect
    let session_alive = (^ssh ...$args $"tmux -L thin has-session -t ($remote_session) 2>/dev/null; echo $?" | str trim) == "0"

    print $"\e[2A\e[2K\e[1B\e[2K\e[1A($remote_session) (if $session_alive { "detached" } else { "killed" })"

    # Cleanup pane options
    tmux set-option -pu @thin_remote_host
    tmux set-option -pu @thin_remote_session
    tmux set-option -pu @thin_remote_port
}

def --wrapped "main list" [
    ...args: string       # SSH args (e.g. -p 8022 user@host)
] {
    if ($args | is-empty) {
        print "Usage: tmux-from-workstation list -- [ssh-args...] <host>"
        print "List remote thin sessions"
        return
    }

    let sessions = try {
        ^ssh ...$args "tmux -L thin list-sessions -F '#{session_name}:#{session_attached}'" | lines
    } catch {
        print "No remote thin tmux server running"
        return
    }

    if ($sessions | is-empty) {
        print "No remote thin sessions"
        return
    }

    $sessions | each {|s|
        let parts = ($s | split row ":")
        let name = ($parts | get 0)
        let attached = if ($parts | get 1) == "1" { "attached" } else { "detached" }
        $"($name) \(($attached)\)"
    } | str join "\n" | print
}

def --wrapped "main reconnect" [
    ...args: string       # SSH args (e.g. [-s session] -p 8022 user@host)
] {
    if ($args | is-empty) {
        print "Usage: tmux-from-workstation reconnect [-s session] -- [ssh-args...] <host>"
        print "Reconnect to a detached remote thin session"
        return
    }

    # Extract optional -s session_name
    let target_session = if ($args | any {|a| $a == "-s"}) {
        let idx = ($args | enumerate | where {|e| $e.item == "-s"} | first | get index)
        $args | get ($idx + 1)
    } else { null }

    let ssh_args = if ($target_session != null) {
        let idx = ($args | enumerate | where {|e| $e.item == "-s"} | first | get index)
        $args | enumerate | where {|e| $e.index != $idx and $e.index != ($idx + 1)} | get item
    } else { $args }

    let hostname = parse-hostname $ssh_args

    if ($hostname == null) {
        print "Error: could not determine hostname from args"
        return
    }

    let in_tmux = ($env | get -o TMUX | is-not-empty)

    if not $in_tmux {
        print "Error: must be inside a tmux session (local fat side)"
        return
    }

    # List sessions
    let sessions = try {
        ^ssh ...$ssh_args "tmux -L thin list-sessions -F '#{session_name}:#{session_attached}'" | lines
    } catch {
        print "No remote thin tmux server running"
        return
    }

    let all_sessions = ($sessions | each {|s| $s | split row ":" | first})

    if ($all_sessions | is-empty) {
        print "No remote thin sessions"
        return
    }

    let session = if ($target_session != null) {
        if ($target_session in $all_sessions) {
            $target_session
        } else {
            print $"Session ($target_session) not found"
            print $"Available: ($all_sessions | str join ', ')"
            return
        }
    } else if ($all_sessions | length) == 1 {
        $all_sessions | first
    } else {
        $sessions | each {|s|
            let parts = ($s | split row ":")
            let status = if ($parts | get 1) == "1" { "attached" } else { "detached" }
            $"($parts | get 0) \(($status)\)"
        } | str join "\n" | fzf --prompt "Select session: " | str replace ' (attached)' '' | str replace ' (detached)' '' | str trim
    }

    if ($session | is-empty) {
        return
    }

    # Store connection metadata
    tmux set-option -p @thin_remote_host $hostname
    tmux set-option -p @thin_remote_session $session
    tmux set-option -p @thin_remote_port (get-port $ssh_args)

    # Copy config and attach
    let config_path = ($env.HOME | path join ".dotfiles/tmux/tmux-thin-remote.conf")
    ^scp -q ...(scp-port-args $ssh_args) $config_path $"($hostname):/tmp/tmux-thin-remote.conf"

    try {
        ^ssh -t ...$ssh_args $"bash -l -c 'tmux -L thin -f /tmp/tmux-thin-remote.conf attach-session -t ($session)'"
    } catch {
        print $"Error: failed to reconnect to ($hostname)"
    }

    let session_alive = (^ssh ...$ssh_args $"tmux -L thin has-session -t ($session) 2>/dev/null; echo $?" | str trim) == "0"

    print $"\e[2A\e[2K\e[1B\e[2K\e[1A($session) (if $session_alive { "detached" } else { "killed" })"

    # Cleanup pane options
    tmux set-option -pu @thin_remote_host
    tmux set-option -pu @thin_remote_session
    tmux set-option -pu @thin_remote_port
}

def --wrapped "main cleanup" [
    ...args: string       # SSH args (e.g. -p 8022 user@host)
] {
    if ($args | is-empty) {
        print "Usage: tmux-from-workstation cleanup -- [ssh-args...] <host>"
        print "Kill all unattached remote thin sessions"
        return
    }

    let sessions = try {
        ^ssh ...$args "tmux -L thin list-sessions -F '#{session_name}:#{session_attached}'" | lines
    } catch {
        print "No remote thin tmux server running"
        return
    }

    let unattached = ($sessions | where {|s| ($s | str ends-with ":0")} | each {|s| $s | split row ":" | first})

    if ($unattached | is-empty) {
        print "No unattached remote thin sessions"
        return
    }

    for session in $unattached {
        ^ssh ...$args $"tmux -L thin kill-session -t ($session)"
        print $"Killed remote thin session: ($session)"
    }
}

def main [] {
    print "tmux-from-workstation - local fat, remote thin"
    print ""
    print "Commands:"
    print "  connect -- [ssh-args] <host>            Connect to remote (start thin session)"
    print "  list -- [ssh-args] <host>               List remote thin sessions"
    print "  reconnect [-s session] -- [ssh-args] <host>  Reconnect to remote thin session"
    print "  cleanup -- [ssh-args] <host>            Kill unattached remote thin sessions"
}
```

**Key edge case handling vs original spec:**
- scp failure is now checked before proceeding to SSH (prevents confusing errors)

**Step 2: Make executable and verify syntax**

Run: `chmod +x nushell/actions/tmux-from-workstation && nu nushell/actions/tmux-from-workstation`
Expected: prints help text without errors

**Step 3: Commit**

```bash
git add nushell/actions/tmux-from-workstation
git commit -m "feat: add tmux-from-workstation script (local fat, remote thin)"
```

---

### Task 4: Create `tmux-to-workstation` script

Local is thin, remote is fat. Manages local thin sessions. Subcommands: `connect`, `list`, `reconnect`, `cleanup`.

**Files:**
- Create: `nushell/actions/tmux-to-workstation`

**Done when:** Script runs (`nu nushell/actions/tmux-to-workstation` prints help), all four subcommands parse without syntax errors.

**Step 1: Write the script**

Key differences from `tmux-from-workstation`:
- `connect` picks the remote session FIRST (while still in fat tmux where fzf works), THEN detaches from fat, THEN starts thin
- Uses `tmux new-window "ssh -t ..."` to make SSH the window's direct command (no send-keys race)
- `list`/`reconnect`/`cleanup` operate on LOCAL thin tmux (`tmux -L thin ...`) — no SSH needed
- Stores `@remote_name` on the thin tmux window for title propagation
- `cleanup` relies on `remain-on-exit on` in `tmux-thin-local.conf` to find dead panes

```nu
#!/usr/bin/env nu
# tmux-to-workstation: local thin, remote fat
# Connect to remote where the full tmux UI lives
# Symlinked to ~/.local/bin/tmux-to-workstation via rotz

# Extract hostname from SSH args (same pattern as tmux-ssh)
def parse-hostname [args: list<string>]: nothing -> string {
    $args
        | reduce --fold { skip: false, host: null } {|arg, acc|
            if $acc.skip {
                { skip: false, host: $acc.host }
            } else if ($arg | str starts-with "-") {
                let value_flags = ["-p" "-l" "-i" "-o" "-F" "-J" "-L" "-R" "-D" "-W" "-E" "-S" "-b" "-c" "-e" "-m" "-O" "-Q" "-w" "-B"]
                if ($arg in $value_flags) {
                    { skip: true, host: $acc.host }
                } else {
                    { skip: false, host: $acc.host }
                }
            } else if ($acc.host == null) {
                { skip: false, host: $arg }
            } else {
                $acc
            }
        }
        | get host
}

# Extract port value from ssh args
def get-port [args: list<string>]: nothing -> string {
    if ($args | any {|a| $a == "-p"}) {
        let port_idx = ($args | enumerate | where {|e| $e.item == "-p"} | first | get index)
        $args | get ($port_idx + 1)
    } else { "" }
}

def --wrapped "main connect" [
    ...args: string       # SSH args (e.g. -p 8022 user@host)
] {
    if ($args | is-empty) {
        main
        return
    }

    let hostname = parse-hostname $args

    if ($hostname == null) {
        print "Error: could not determine hostname from args"
        return
    }

    let display_host = if ($hostname | str contains "@") {
        $hostname | split row "@" | last
    } else {
        $hostname
    }

    let port = get-port $args

    # Pick remote session BEFORE detaching from fat tmux (fzf needs a terminal)
    let remote_sessions = try {
        ^ssh ...$args "tmux list-sessions -F '#{session_name}:#{session_attached}'" | lines
    } catch {
        []
    }

    let remote_session = if ($remote_sessions | is-empty) {
        # No sessions on remote — will create new "main" session
        "main"
    } else {
        let all = ($remote_sessions | each {|s| $s | split row ":" | first})
        if ($all | length) == 1 {
            $all | first
        } else {
            $remote_sessions | each {|s|
                let parts = ($s | split row ":")
                let status = if ($parts | get 1) == "1" { "attached" } else { "detached" }
                $"($parts | get 0) \(($status)\)"
            } | str join "\n" | fzf --prompt "Remote session: " | str replace ' (attached)' '' | str replace ' (detached)' '' | str trim
        }
    }

    if ($remote_session | is-empty) {
        return
    }

    # Detach from local fat tmux if inside one (on the default socket)
    if ($env | get -o TMUX | is-not-empty) {
        tmux detach-client
    }

    # Thin window name encodes connection info
    let thin_window = $"($display_host)_($remote_session)"

    # Build the SSH command that will be the window's process
    # When SSH exits (disconnect/drop), pane stays alive due to remain-on-exit
    let ssh_cmd = $"ssh -t ($args | str join ' ') 'tmux attach-session -t ($remote_session) || tmux new-session -s ($remote_session)'"

    # Start or extend thin tmux
    let config_path = ($env.HOME | path join ".dotfiles/tmux/tmux-thin-local.conf")
    let thin_running = (do { tmux -L thin list-sessions } | complete | get exit_code) == 0

    if $thin_running {
        # Create new window with SSH as its command (no send-keys race)
        tmux -L thin new-window -n $thin_window $ssh_cmd
    } else {
        # Start thin server — first window runs SSH directly
        tmux -L thin -f $config_path new-session -d -s thin -n $thin_window $ssh_cmd
    }

    # Store connection metadata on the thin window (for display and reconnect)
    tmux -L thin set-option -w -t $thin_window @remote_name $display_host
    tmux -L thin set-option -w -t $thin_window @remote_host $hostname
    tmux -L thin set-option -w -t $thin_window @remote_session $remote_session
    tmux -L thin set-option -w -t $thin_window @remote_port $port
    tmux -L thin set-option -w -t $thin_window @ssh_args ($args | str join " ")

    # Attach to thin tmux
    tmux -L thin attach-session -t thin
}

def "main list" [] {
    # List local thin windows — no SSH needed
    # Use -t thin to be explicit about which session, and -a is not needed
    let windows = try {
        tmux -L thin list-windows -t thin -F '#{window_name}:#{window_active}:#{pane_dead}' | lines
    } catch {
        print "No local thin tmux running"
        return
    }

    if ($windows | is-empty) {
        print "No thin windows"
        return
    }

    $windows | each {|w|
        let parts = ($w | split row ":")
        let name = ($parts | get 0)
        let active = if ($parts | get 1) == "1" { "*" } else { "" }
        let dead = if ($parts | get 2) == "1" { "(dead)" } else { "(connected)" }
        $"($name) ($dead) ($active)" | str trim
    } | str join "\n" | print
}

def "main reconnect" [
    session?: string     # Optional: specific thin window name to switch to
] {
    # Check thin tmux is running
    let thin_running = (do { tmux -L thin list-sessions } | complete | get exit_code) == 0

    if not $thin_running {
        print "No local thin tmux running"
        return
    }

    if ($session != null) {
        # Select specific window then attach
        tmux -L thin select-window -t $session
    }

    # Attach to thin tmux
    tmux -L thin attach-session -t thin
}

def "main cleanup" [] {
    # Kill thin tmux windows where SSH has exited (pane is dead)
    # This works because tmux-thin-local.conf has remain-on-exit on
    let windows = try {
        tmux -L thin list-windows -t thin -F '#{window_name}:#{window_id}:#{pane_dead}' | lines
    } catch {
        print "No local thin tmux running"
        return
    }

    let dead = ($windows | where {|w| ($w | str ends-with ":1")} | each {|w|
        let parts = ($w | split row ":")
        { name: ($parts | get 0), id: ($parts | get 1) }
    })

    if ($dead | is-empty) {
        print "No dead thin windows"
        return
    }

    for win in $dead {
        tmux -L thin kill-window -t $win.id
        print $"Killed thin window: ($win.name)"
    }
}

def main [] {
    print "tmux-to-workstation - local thin, remote fat"
    print ""
    print "Commands:"
    print "  connect -- [ssh-args] <host>   Connect to remote fat session"
    print "  list                           List local thin windows"
    print "  reconnect [session]            Reattach to local thin tmux"
    print "  cleanup                        Kill dead thin windows"
}
```

**Critical fixes vs original spec:**
1. **fzf before detach**: Session selection happens while still in fat tmux (lines 83-101), detach happens after (line 108). Prevents stranding user outside tmux if fzf fails.
2. **SSH as window command**: Uses `tmux new-window -n name "ssh ..."` (line 121) instead of `send-keys`. No race condition — SSH starts immediately as the window's process.
3. **`remain-on-exit` dependency**: `cleanup` uses `#{pane_dead}` which requires `remain-on-exit on` in `tmux-thin-local.conf` (added in Task 1). This is documented in both tasks.
4. **`list` shows connection status**: Each window shows `(connected)` or `(dead)` using `#{pane_dead}`.
5. **Explicit session target**: `list-windows -t thin` prevents ambiguity.

**Step 2: Make executable and verify syntax**

Run: `chmod +x nushell/actions/tmux-to-workstation && nu nushell/actions/tmux-to-workstation`
Expected: prints help text without errors

**Step 3: Commit**

```bash
git add nushell/actions/tmux-to-workstation
git commit -m "feat: add tmux-to-workstation script (local thin, remote fat)"
```

---

### Task 5: Wire up rotz linking and aliases

Add symlinks and aliases so the new scripts are available as commands.

**Files:**
- Modify: `nushell/dot.yaml` — add link entries and chmod (linux section only — these tools need tmux/SSH, not available on Windows host)
- Modify: `nushell/config.nu:710-714` — add aliases

**Done when:** `rotz link nushell --force` creates symlinks in `~/.local/bin/`, aliases resolve in nushell.

**Step 1: Add links to `nushell/dot.yaml`**

In the `linux:` → `links:` section (after `actions/tmux-ssh: ~/.local/bin/tmux-ssh` at line 32), add:

```yaml
    actions/tmux-to-workstation: ~/.local/bin/tmux-to-workstation
    actions/tmux-from-workstation: ~/.local/bin/tmux-from-workstation
```

In the `linux:` → `installs:` → `cmd:` section (after `chmod +x ~/.dotfiles/nushell/actions/tmux-ssh` at line 62), add:

```bash
      chmod +x ~/.dotfiles/nushell/actions/tmux-to-workstation
      chmod +x ~/.dotfiles/nushell/actions/tmux-from-workstation
```

Do NOT add to the `windows:` section — these tools require tmux and SSH which are not available on Windows host side.

**Step 2: Add aliases to `nushell/config.nu`**

After line 714 (`alias tsx = tmux-ssh cleanup`), add:

```nu
# tmux-to-workstation
alias ttw = tmux-to-workstation connect
alias ttwl = tmux-to-workstation list
alias ttwr = tmux-to-workstation reconnect
alias ttwx = tmux-to-workstation cleanup

# tmux-from-workstation
alias tfw = tmux-from-workstation connect
alias tfwl = tmux-from-workstation list
alias tfwr = tmux-from-workstation reconnect
alias tfwx = tmux-from-workstation cleanup
```

**Step 3: Commit**

```bash
git add nushell/dot.yaml nushell/config.nu
git commit -m "feat: wire up tmux-to/from-workstation linking and aliases"
```

---

### Task 6: Manual smoke test

No automated tests — these are interactive SSH+tmux scripts. Verify manually.

**Done when:** All scenarios below verified, existing `tmux-ssh` still works.

**Step 1: Test `tmux-from-workstation` (requires a remote server with tmux)**

```bash
# From inside local fat tmux:
tmux-from-workstation connect <server-host>
# Expected: SSHs to remote, opens thin tmux session
# Ctrl-D or exit to disconnect
# Expected: prints "session_name detached" or "session_name killed"

tmux-from-workstation list -- <server-host>
# Expected: lists remote thin sessions with attached/detached status

tmux-from-workstation cleanup -- <server-host>
# Expected: kills unattached sessions, prints each killed name
```

**Step 2: Test `tmux-to-workstation` (requires a second machine with tmux)**

```bash
# From any machine:
tmux-to-workstation connect <workstation-host>
# Expected: picks remote session (fzf if multiple), detaches from local fat, starts thin, SSHs to remote fat
# Expected: WM title bar shows [workstation-host]

# Detach from thin (Ctrl-B d won't work — no prefix; close terminal instead)
tmux-to-workstation list
# Expected: lists thin windows with (connected)/(dead) status

tmux-to-workstation reconnect
# Expected: reattaches to thin tmux

# Kill SSH (e.g., unplug network), then:
tmux-to-workstation list
# Expected: window shows (dead)

tmux-to-workstation cleanup
# Expected: kills dead windows
```

**Step 3: Verify existing `tmux-ssh` still works (no regression)**

```bash
tsc -- <any-host>
tsl -- <any-host>
# Expected: no change in behavior — tmux-ssh uses -L remote, new tools use -L thin
```
