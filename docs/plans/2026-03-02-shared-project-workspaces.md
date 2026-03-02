# Shared Project Workspace System (i3 + Sway) Implementation Plan

> **For Claude:** Use infinifu:executing-plans, infinifu:subagent-driven-development, or infinifu:scrum-master to implement this plan.

**Goal:** Make the project workspace system (rofi picker, positional switching, tmux session alignment) work identically on both i3 and sway by sharing scripts with a WM detection abstraction.

**Architecture:** Create a `wm-ipc.nu` module that auto-detects i3 vs sway and provides a unified IPC interface. Move the three project workspace scripts from `i3/scripts/` to `nushell/actions/` so both WMs share them via `~/.local/bin/`. Update bashrc to detect either WM for tmux project alignment. Update sway config with matching keybindings.

**Tech Stack:** Nushell scripts, rofi, swaymsg/i3-msg IPC, bash, rotz (dot.yaml)

---

### Task 1: Create wm-ipc.nu module

**Files:**
- Create: `nushell/actions/wm-ipc.nu`

**Step 1: Create the WM detection module**

Create `nushell/actions/wm-ipc.nu`:

```nushell
#!/usr/bin/env nu

# WM IPC abstraction — detects i3 or sway and provides unified commands.
# Used by ws-list.nu, ws-switch.nu, project-picker.

# Detect which WM is running and return the IPC command name
export def ipc-cmd [] {
    # Check sway first (if both are somehow running, prefer the Wayland session)
    if (^pgrep -x sway | complete | get exit_code) == 0 {
        "swaymsg"
    } else if (^pgrep -x i3 | complete | get exit_code) == 0 {
        "i3-msg"
    } else {
        null
    }
}

# Run a WM IPC command with the given arguments
# Returns null if no WM detected
export def ipc [...args: string] {
    let cmd = ipc-cmd
    if $cmd == null { return null }
    ^$cmd ...$args
}
```

**Step 2: Commit**

```bash
git add nushell/actions/wm-ipc.nu
git commit -m "feat: add wm-ipc.nu for i3/sway IPC abstraction"
```

---

### Task 2: Move ws-list.nu to nushell/actions and use wm-ipc

**Files:**
- Move: `i3/scripts/ws-list.nu` → `nushell/actions/ws-list.nu`
- Modify: update all `i3-msg` references to use `wm-ipc.nu`

**Step 1: Move the file**

```bash
git mv i3/scripts/ws-list.nu nushell/actions/ws-list.nu
```

**Step 2: Update ws-list.nu to use wm-ipc**

Replace the entire file content. Key changes:
- Add `const wm_ipc = '~/.local/bin/wm-ipc.nu'` and `use $wm_ipc *`
- Replace `i3-msg -t get_workspaces | from json` with `ipc -t get_workspaces | from json`
- Replace `i3-msg $"rename workspace ..."` with `ipc $"rename workspace ..."`
- Replace `i3-msg $"workspace ..."` with `ipc ...`

Updated file:

```nushell
#!/usr/bin/env nu

# Shared WM workspace utilities
# Used by ws-switch.nu and project-picker
#
# Workspace naming convention:
#   Single workspace:   "projectname"  (no suffix)
#   Multiple:           "projectname_1", "projectname_2", ...

const wm_ipc = '~/.local/bin/wm-ipc.nu'
use $wm_ipc *

# Get all workspaces sorted in display order (by num ascending)
export def sorted [] {
	ipc -t get_workspaces | from json | sort-by num
}

# Get the focused workspace
export def focused [] {
	sorted | where focused == true | first
}

# Find existing workspaces for a project
# Matches both "name" (single) and "name_N" (multiple) patterns
export def for-project [name: string] {
	sorted | where { |ws| $ws.name == $name or $ws.name =~ $"^($name)_\\d+$" }
}

# Normalize project workspaces: if only one numbered workspace exists, rename to bare name
# e.g. "dotfiles_1" (alone) -> "dotfiles"
export def normalize [name: string] {
	let existing = for-project $name
	if ($existing | length) == 1 {
		let ws = ($existing | first | get name)
		if $ws != $name {
			ipc rename workspace $"\"($ws)\"" to $"\"($name)\""
		}
	}
}

# Extract project name from a workspace name
# "dotfiles" -> "dotfiles", "dotfiles_1" -> "dotfiles", "3" -> null
export def project-name [ws_name: string] {
	if ($ws_name =~ '^.+_\d+$') {
		$ws_name | parse --regex '^(?P<project>.+)_\d+$' | first | get project
	} else if ($ws_name =~ '^\d+$') {
		# pure numeric workspace, not a project
		null
	} else {
		# bare name, could be a project
		$ws_name
	}
}
```

**Important:** The `ipc rename workspace` call syntax changes slightly — we pass individual args instead of a single interpolated string, because `ipc` uses `^$cmd ...$args`. Verify that `swaymsg rename workspace "old" to "new"` works the same as `i3-msg` (it does — same IPC protocol).

**Step 3: Commit**

```bash
git add nushell/actions/ws-list.nu
git commit -m "refactor: move ws-list.nu to nushell/actions, use wm-ipc"
```

---

### Task 3: Move ws-switch.nu to nushell/actions and use wm-ipc

**Files:**
- Move: `i3/scripts/ws-switch.nu` → `nushell/actions/ws-switch.nu`
- Modify: update `i3-msg` references and `use` path

**Step 1: Move the file**

```bash
git mv i3/scripts/ws-switch.nu nushell/actions/ws-switch.nu
```

**Step 2: Update ws-switch.nu**

Key changes:
- Change `const ws_list = '~/.config/polybar/scripts/ws-list.nu'` → `const ws_list = '~/.local/bin/ws-list.nu'`
- Add `const wm_ipc = '~/.local/bin/wm-ipc.nu'` and `use $wm_ipc *`
- Replace `i3-msg` calls with `ipc` calls

Updated file:

```nushell
#!/usr/bin/env nu

# Switch to workspace by display order (matching bar module with index-sort)
# Usage: ws-switch.nu <index>         — switch to Nth workspace (1-based)
# Usage: ws-switch.nu <index> move    — move container to Nth workspace
# Usage: ws-switch.nu <index> follow  — move container to Nth workspace and follow

const ws_list = '~/.local/bin/ws-list.nu'
use $ws_list *

const wm_ipc = '~/.local/bin/wm-ipc.nu'
use $wm_ipc *

const config_path = '~/.config/project/projects.yaml'

def get-project-names [] {
	let path = ($config_path | path expand)
	if ($path | path exists) {
		open $path | get -o projects | default {} | columns
	} else {
		[]
	}
}

def normalize-all [] {
	get-project-names | each { |name| normalize $name } | ignore
}

def main [
	index: int       # 1-based position in bar display order
	action?: string  # "move" to move container, "follow" to move and follow
] {
	# normalize orphaned _N names before resolving index
	normalize-all

	let workspaces = sorted

	if $index < 1 or $index > ($workspaces | length) {
		return
	}

	let target = ($workspaces | get ($index - 1))

	match $action {
		"move" => {
			ipc move container to workspace $target.name | ignore
			normalize-all
		},
		"follow" => {
			ipc move container to workspace ($target.name) | ignore
			ipc workspace ($target.name) | ignore
			normalize-all
		},
		_ => {
			if not $target.focused {
				ipc workspace ($target.name) | ignore
			}
		}
	}
}
```

**Note on IPC call syntax:** The original uses `i3-msg $"move container to workspace ($target.name); workspace ($target.name)"` (semicolon-separated commands). For the `ipc` wrapper, we split into two separate calls for the follow case since `swaymsg` also supports semicolons but separate calls are clearer. Both approaches work — test which is more reliable. If semicolons are preferred, use: `ipc $"move container to workspace ($target.name); workspace ($target.name)"`.

**Step 3: Commit**

```bash
git add nushell/actions/ws-switch.nu
git commit -m "refactor: move ws-switch.nu to nushell/actions, use wm-ipc"
```

---

### Task 4: Move project-picker.nu to nushell/actions and use wm-ipc

**Files:**
- Move: `i3/scripts/project-picker.nu` → `nushell/actions/project-picker`
- Modify: update `i3-msg` references and `use` path

Note: rename to `project-picker` (no `.nu` extension) for cleaner `~/.local/bin/project-picker` invocation.

**Step 1: Move the file**

```bash
git mv i3/scripts/project-picker.nu nushell/actions/project-picker
```

**Step 2: Update project-picker**

Key changes:
- Change `const ws_list` path from polybar to `~/.local/bin/ws-list.nu`
- Add `const wm_ipc` and `use $wm_ipc *`
- Replace all `i3-msg` calls with `ipc` calls

Updated file:

```nushell
#!/usr/bin/env nu

# Project workspace picker (works with i3 and sway)
# Called by WM keybinding ($mod+p / $mod+Shift+p)
# Uses rofi to select a project, then switches to or creates a workspace
#
# Naming: single workspace = "projectname", multiple = "projectname_1", "projectname_2"

const ws_list = '~/.local/bin/ws-list.nu'
use $ws_list *

const wm_ipc = '~/.local/bin/wm-ipc.nu'
use $wm_ipc *

const config_path = '~/.config/project/projects.yaml'

# read projects registry
def get-projects [] {
	let path = ($config_path | path expand)
	if ($path | path exists) {
		open $path | get -o projects | default {}
	} else {
		{}
	}
}

def main [
	--new (-n) # force create new workspace even if one exists
] {
	let projects = get-projects

	if ($projects | columns | is-empty) {
		return
	}

	# normalize workspace names before building the list
	# (cleans up orphaned _N names when only one workspace remains)
	$projects | columns | each { |name| normalize $name } | ignore

	# detect current project (to exclude from switch list)
	let current_project = (project-name (focused).name)

	# build rofi lines: "name  [ws, ws_1, ws_2]" or "name"
	# for switch mode ($mod+p): skip the project we're already on
	# for new mode ($mod+Shift+p): show all projects including current
	let project_list = if $new {
		$projects | columns
	} else {
		$projects | columns | where { |name| $name != $current_project }
	}
	let lines = ($project_list | each { |name|
		let pws = for-project $name
		if ($pws | is-empty) {
			$name
		} else {
			let ws_names = ($pws | get name | str join ", ")
			$"($name)  [($ws_names)]"
		}
	} | str join "\n")

	# show rofi picker
	let selected = ($lines | rofi -dmenu -p "Project" -i | str trim)

	if ($selected | is-empty) {
		return
	}

	# extract project name (strip workspace info suffix if present)
	let name = ($selected | split row "  " | first | str trim)

	let existing = for-project $name

	if $new {
		if ($existing | length) == 0 {
			ipc workspace $name | ignore
		} else {
			# rename bare name to _1 if needed
			if ($existing | any { |ws| $ws.name == $name }) {
				ipc rename workspace $"\"($name)\"" to $"\"($name)_1\"" | ignore
			}
			# find max existing index and create next
			let next = ($existing | each { |ws|
				if $ws.name == $name { 1 } else { $ws.name | str replace $"($name)_" "" | into int }
			} | math max) + 1
			ipc workspace $"($name)_($next)" | ignore
		}
	} else {
		if ($existing | is-empty) {
			ipc workspace $name | ignore
		} else {
			ipc workspace ($existing | first | get name) | ignore
		}
	}
}
```

**Step 3: Commit**

```bash
git add nushell/actions/project-picker
git commit -m "refactor: move project-picker to nushell/actions, use wm-ipc"
```

---

### Task 5: Update nushell/dot.yaml — add symlinks for new scripts

**Files:**
- Modify: `nushell/dot.yaml`

**Step 1: Add symlinks**

Add these lines to both the `windows:` and `linux:` `links:` sections of `nushell/dot.yaml`:

For `linux:` links (add after the existing tmux-project line):

```yaml
    actions/wm-ipc.nu: ~/.local/bin/wm-ipc.nu
    actions/ws-list.nu: ~/.local/bin/ws-list.nu
    actions/ws-switch.nu: ~/.local/bin/ws-switch.nu
    actions/project-picker: ~/.local/bin/project-picker
```

Do NOT add these to the `windows:` section — WM IPC is Linux-only.

**Step 2: Add chmod lines to installs**

In the `linux:` `installs:` `cmd:` section, add after the existing chmod lines:

```bash
      chmod +x ~/.dotfiles/nushell/actions/wm-ipc.nu
      chmod +x ~/.dotfiles/nushell/actions/ws-list.nu
      chmod +x ~/.dotfiles/nushell/actions/ws-switch.nu
      chmod +x ~/.dotfiles/nushell/actions/project-picker
```

**Step 3: Commit**

```bash
git add nushell/dot.yaml
git commit -m "feat: add symlinks for shared WM project scripts"
```

---

### Task 6: Update i3/dot.yaml — remove scripts directory symlink

**Files:**
- Modify: `i3/dot.yaml`

**Step 1: Update i3 dot.yaml**

The current i3/dot.yaml has:
```yaml
    scripts: ~/.config/polybar/scripts
```

This symlinks the entire `i3/scripts/` directory to `~/.config/polybar/scripts`. After moving the 3 project scripts out, the directory still contains `disk.nu`, `ram.nu`, and `scripts/` which are polybar-specific. Keep this symlink — it still serves polybar. No change needed to `i3/dot.yaml`.

However, remove the `chmod +x ~/.dotfiles/i3/scripts/*.nu` line from `i3/dot.yaml` installs if the moved scripts are no longer there. Actually — `disk.nu` and `ram.nu` still need chmod. The glob `*.nu` will still match them. So no change is needed.

**Step 2: Update i3/config keybindings**

Modify `i3/config` to use the new `~/.local/bin/` paths:

Change line 155:
```
set $ws_switch ~/.config/polybar/scripts/ws-switch.nu
```
to:
```
set $ws_switch ~/.local/bin/ws-switch.nu
```

Change lines 260-261:
```
bindsym $mod+p exec --no-startup-id ~/.config/polybar/scripts/project-picker.nu
bindsym $mod+Shift+p exec --no-startup-id ~/.config/polybar/scripts/project-picker.nu --new
```
to:
```
bindsym $mod+p exec --no-startup-id ~/.local/bin/project-picker
bindsym $mod+Shift+p exec --no-startup-id ~/.local/bin/project-picker --new
```

**Step 3: Commit**

```bash
git add i3/config
git commit -m "refactor: update i3 config to use shared script paths"
```

---

### Task 7: Update sway config with project keybindings

**Files:**
- Modify: `sway/config.d/default`

**Step 1: Replace workspace bindings**

In `sway/config.d/default`, replace the entire "Workspaces" section (lines 161-186) with project-aware keybindings:

Remove:
```
    # Switch to workspace
    bindsym $mod+1 workspace number 1
    bindsym $mod+2 workspace number 2
    ...through $mod+0
    # Move focused container to workspace
    bindsym $mod+Shift+1 move container to workspace number 1
    bindsym $mod+Shift+2 move container to workspace number 2
    ...through $mod+Shift+0
```

Replace with:
```
# Workspace switching by display order (supports named project workspaces)
set $ws_switch ~/.local/bin/ws-switch.nu

# switch to workspace by display position
bindsym $mod+1 exec $ws_switch 1
bindsym $mod+2 exec $ws_switch 2
bindsym $mod+3 exec $ws_switch 3
bindsym $mod+4 exec $ws_switch 4
bindsym $mod+5 exec $ws_switch 5
bindsym $mod+6 exec $ws_switch 6
bindsym $mod+7 exec $ws_switch 7
bindsym $mod+8 exec $ws_switch 8

# Move focused container to workspace by display position
bindsym $mod+Ctrl+1 exec $ws_switch 1 move
bindsym $mod+Ctrl+2 exec $ws_switch 2 move
bindsym $mod+Ctrl+3 exec $ws_switch 3 move
bindsym $mod+Ctrl+4 exec $ws_switch 4 move
bindsym $mod+Ctrl+5 exec $ws_switch 5 move
bindsym $mod+Ctrl+6 exec $ws_switch 6 move
bindsym $mod+Ctrl+7 exec $ws_switch 7 move
bindsym $mod+Ctrl+8 exec $ws_switch 8 move

# Move container to workspace and follow
bindsym $mod+Shift+1 exec $ws_switch 1 follow
bindsym $mod+Shift+2 exec $ws_switch 2 follow
bindsym $mod+Shift+3 exec $ws_switch 3 follow
bindsym $mod+Shift+4 exec $ws_switch 4 follow
bindsym $mod+Shift+5 exec $ws_switch 5 follow
bindsym $mod+Shift+6 exec $ws_switch 6 follow
bindsym $mod+Shift+7 exec $ws_switch 7 follow
bindsym $mod+Shift+8 exec $ws_switch 8 follow
```

**Step 2: Add project picker keybindings**

Add before the "Layout stuff" section:

```
# Project workspace picker (rofi)
bindsym $mod+p exec ~/.local/bin/project-picker
bindsym $mod+Shift+p exec ~/.local/bin/project-picker --new
```

**Step 3: Add workspace next/prev navigation**

Add before the ws_switch block:

```
# Navigate workspaces next / previous
bindsym $mod+Ctrl+Right workspace next
bindsym $mod+Ctrl+Left workspace prev
```

**Step 4: Commit**

```bash
git add sway/config.d/default
git commit -m "feat: add project workspace keybindings to sway config"
```

---

### Task 8: Update bashrc with generic WM detection

**Files:**
- Modify: `distro/bashrc`

**Step 1: Replace the i3-specific block**

Replace the current block (lines 19-36):

```bash
	# Detect i3 project workspace to align tmux session group with project
	PROJECT=""
	if command -v i3-msg &>/dev/null; then
		ws_name=$(i3-msg -t get_workspaces 2>/dev/null \
```

With a generic WM detection version:

```bash
	# Detect WM project workspace to align tmux session group with project
	PROJECT=""
	WM_MSG=""
	if command -v swaymsg &>/dev/null && pgrep -x sway &>/dev/null; then
		WM_MSG="swaymsg"
	elif command -v i3-msg &>/dev/null && pgrep -x i3 &>/dev/null; then
		WM_MSG="i3-msg"
	fi

	if [ -n "$WM_MSG" ]; then
		ws_name=$($WM_MSG -t get_workspaces 2>/dev/null \
			| grep -o '"name":"[^"]*","visible":true,"focused":true' \
			| grep -o '"name":"[^"]*"' \
			| sed 's/"name":"//;s/"//')
		# Match numbered project workspace: <name>_<digits>
		if [[ "$ws_name" =~ ^(.+)_[0-9]+$ ]]; then
			PROJECT="${BASH_REMATCH[1]}"
		# Match bare project name (non-numeric, check against projects.yaml)
		elif [[ -n "$ws_name" && ! "$ws_name" =~ ^[0-9]+$ ]]; then
			config="$HOME/.config/project/projects.yaml"
			if [[ -f "$config" ]] && grep -q "^  ${ws_name}:" "$config" 2>/dev/null; then
				PROJECT="$ws_name"
			fi
		fi
	fi
```

The workspace name extraction logic (grep/sed) is identical — both i3-msg and swaymsg return the same JSON format for `get_workspaces`.

**Step 2: Commit**

```bash
git add distro/bashrc
git commit -m "feat: bashrc detects sway workspaces for project tmux alignment"
```

---

### Task 9: Verify and clean up

**Step 1: Verify no dangling references**

Check that nothing still references the old polybar script paths:

```bash
rg "polybar/scripts/ws-" --type-not yaml
rg "polybar/scripts/project-picker"
```

Expected: no matches (the polybar config.ini doesn't reference these scripts, only polybar bar modules reference disk.nu/ram.nu).

**Step 2: Verify script shebangs and executability**

```bash
head -1 nushell/actions/wm-ipc.nu nushell/actions/ws-list.nu nushell/actions/ws-switch.nu nushell/actions/project-picker
```

All should have `#!/usr/bin/env nu`.

**Step 3: Run rotz link (if available) to verify symlinks**

```bash
rotz link nushell --dry-run 2>/dev/null || echo "rotz not available, skip"
```

**Step 4: Final commit if any cleanup was needed**

```bash
git add -A
git status
# If changes exist:
git commit -m "chore: clean up dangling references after script migration"
```

---

### Task 10: Update project README

**Files:**
- Modify: `nushell/scripts/project/README.md`

**Step 1: Update architecture docs**

Update the README.md to reflect:
- Scripts now live in `nushell/actions/` (symlinked to `~/.local/bin/`)
- Works with both i3 and sway (wm-ipc abstraction)
- Update the file table to show new locations
- Update the architecture diagram to show sway as an alternative WM layer
- Replace all `i3-msg` references with "WM IPC" or "ipc"

Key changes to the file table:

```markdown
| File | Location (symlinked) | Purpose |
|------|---------------------|---------|
| `nushell/actions/wm-ipc.nu` | `~/.local/bin/wm-ipc.nu` | WM detection (i3/sway) + unified IPC |
| `nushell/actions/ws-list.nu` | `~/.local/bin/ws-list.nu` | Shared workspace utilities |
| `nushell/actions/ws-switch.nu` | `~/.local/bin/ws-switch.nu` | Switch/move by display index |
| `nushell/actions/project-picker` | `~/.local/bin/project-picker` | Rofi project picker |
| `i3/config` | `~/.i3/config` | i3 keybindings |
| `sway/config.d/default` | `~/.config/sway/config.d/default` | Sway keybindings |
```

**Step 2: Commit**

```bash
git add nushell/scripts/project/README.md
git commit -m "docs: update project README for shared i3/sway support"
```
