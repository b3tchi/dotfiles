# Quickshell Sway Compatibility — Implementation Plan

> **For Claude:** Use infinifu:plan-executing, infinifu:plan-subagent, or infinifu:plan-scrum-master to implement this plan.

**Goal:** Extend quickshell (bar, overlay, notifications) to work on sway/WSL while keeping full i3/X11 compatibility.

**Architecture:** Runtime WM detection via `$SWAYSOCK` env var drives command selection (`swaymsg` vs `i3-msg`). `Quickshell.I3` QML module works natively with both WMs. Bar style controlled by `$QS_PHONE` env var instead of Wayland detection.

**Tech Stack:** QML (Quickshell), sway/i3 IPC, rotz (dot.yaml)

---

### Task 1: Add WM detection properties to Bar.qml

**Files:**
- Modify: `quickshell/config/Bar.qml:1-50` (top-level properties)
- Modify: `quickshell/config/Bar.qml:79-91` (mode subscription Process)

**Step 1: Add WM detection properties**

In `quickshell/config/Bar.qml`, after line 14 (`signal dismissNotif()`), add:

```qml
// WM detection — sway uses same IPC as i3
readonly property bool isSway: Qt.getenv("SWAYSOCK") !== ""
readonly property string wmMsg: isSway ? "swaymsg" : "i3-msg"
```

**Step 2: Replace isWayland with isPhone**

Replace lines 38-43:
```qml
// Phone (Wayland): floating with margins; desktop (X11): full-width
readonly property bool isWayland: Qt.platform.pluginName.startsWith("wayland")
margins {
    bottom: isWayland ? 20 : 0
    left:   isWayland ? 40 : 0
    right:  isWayland ? 40 : 0
}
```

With:
```qml
// Phone (sxmo): floating pill; desktop (i3/sway): full-width
readonly property bool isPhone: Qt.getenv("QS_PHONE") === "1"
margins {
    bottom: isPhone ? 20 : 0
    left:   isPhone ? 40 : 0
    right:  isPhone ? 40 : 0
}
```

**Step 3: Replace i3-msg in mode subscription**

Replace line 80:
```qml
command: ["i3-msg", "-t", "subscribe", "-m", '["mode"]']
```

With:
```qml
command: [root.wmMsg, "-t", "subscribe", "-m", '["mode"]']
```

**Step 4: Verify i3 still works**

On an i3 session, run:
```bash
~/.dotfiles/quickshell/qs-start.sh
```
Expected: Bar appears at bottom, full-width, workspaces show, mode switching works.

**Step 5: Commit**

```bash
git add quickshell/config/Bar.qml
git commit -m "feat(quickshell): add WM detection, replace isWayland with QS_PHONE"
```

---

### Task 2: Add WM detection to overlay/shell.qml

**Files:**
- Modify: `quickshell/overlay/shell.qml:6-18` (root properties)
- Modify: `quickshell/overlay/shell.qml:140-141` (windowScanner command)
- Modify: `quickshell/overlay/shell.qml:155-158` (window class extraction)
- Modify: `quickshell/overlay/shell.qml:205-207` (focusProc command)
- Modify: `quickshell/overlay/shell.qml:239-252` (projectsScanner command)
- Modify: `quickshell/overlay/shell.qml:328-333` (projectsNew i3-msg calls)

**Step 1: Add WM detection properties**

In `quickshell/overlay/shell.qml`, after line 8 (`id: root`), add:

```qml
// WM detection
readonly property bool isSway: Qt.getenv("SWAYSOCK") !== ""
readonly property string wmMsg: isSway ? "swaymsg" : "i3-msg"
```

**Step 2: Fix windowScanner command**

Replace line 141:
```qml
command: ["sh", "-c", "i3-msg -s $(i3 --get-socketpath) -t get_tree"]
```

With:
```qml
command: ["sh", "-c", root.wmMsg + " -t get_tree"]
```

**Step 3: Fix window class extraction for sway**

Replace line 157:
```qml
cls: (node.window_properties || {})["class"] || ""
```

With:
```qml
cls: node.app_id || (node.window_properties || {})["class"] || ""
```

This tries `app_id` first (sway Wayland-native), falls back to `window_properties.class` (i3/Xwayland).

**Step 4: Fix focusProc command**

Replace line 207:
```qml
focusProc.command = ["sh", "-c", "i3-msg -s $(i3 --get-socketpath) '[con_id=" + win.id + "]' focus"]
```

With:
```qml
focusProc.command = [root.wmMsg, "[con_id=" + win.id + "]", "focus"]
```

**Step 5: Fix projectsScanner command**

Replace the `i3-msg` references in the projectsScanner Process command (lines 243-252). The shell script inside uses `i3-msg -t get_workspaces` and `i3-msg workspace`. Replace all occurrences of `i3-msg` with `" + root.wmMsg + "` in the command string.

Current line 246:
```qml
"WS_JSON=$(i3-msg -t get_workspaces 2>/dev/null || echo '[]'); " +
```
Replace with:
```qml
"WS_JSON=$(" + root.wmMsg + " -t get_workspaces 2>/dev/null || echo '[]'); " +
```

**Step 6: Fix projectsNew function**

In the `projectsNew()` function (around line 328), replace `i3-msg` string literals:

Replace line 328:
```qml
cmds.push("i3-msg rename workspace \\\"" + p.name + "\\\" to \\\"" + p.name + "_1\\\"")
```
With:
```qml
cmds.push(root.wmMsg + " rename workspace \\\"" + p.name + "\\\" to \\\"" + p.name + "_1\\\"")
```

Replace line 332:
```qml
cmds.push("i3-msg workspace " + p.name + "_" + next)
```
With:
```qml
cmds.push(root.wmMsg + " workspace " + p.name + "_" + next)
```

Replace line 316 (the no-workspaces branch):
```qml
projectsWmProc.command = ["i3-msg", "workspace", p.name]
```
With:
```qml
projectsWmProc.command = [root.wmMsg, "workspace", p.name]
```

Replace line 306:
```qml
projectsWmProc.command = ["i3-msg", "workspace", wsName]
```
With:
```qml
projectsWmProc.command = [root.wmMsg, "workspace", wsName]
```

**Step 7: Verify on i3**

```bash
~/.dotfiles/quickshell/qs-start.sh
```
Test: launcher (Alt+D), switcher (Alt+Tab), projects (Alt+P) all work.

**Step 8: Commit**

```bash
git add quickshell/overlay/shell.qml
git commit -m "feat(quickshell): WM-agnostic overlay — swaymsg/i3-msg detection + app_id support"
```

---

### Task 3: Update start scripts for sway compatibility

**Files:**
- Modify: `quickshell/qs-start.sh`
- Modify: `quickshell/qs-bar.sh`
- Modify: `quickshell/qs-overlay.sh`

**Step 1: Update qs-start.sh**

The scripts currently resolve `I3SOCK` only. Add `SWAYSOCK` awareness. Replace lines 6-8 of `qs-start.sh`:

```sh
if [ -z "$I3SOCK" ] && command -v i3 >/dev/null 2>&1; then
    export I3SOCK="$(i3 --get-socketpath 2>/dev/null)"
fi
```

With:
```sh
if [ -n "$SWAYSOCK" ]; then
    : # Sway — SWAYSOCK already set by sway
elif [ -z "$I3SOCK" ] && command -v i3 >/dev/null 2>&1; then
    export I3SOCK="$(i3 --get-socketpath 2>/dev/null)"
fi
```

**Step 2: Update qs-bar.sh**

Same change — replace lines 6-8 with the sway-aware version from Step 1.

**Step 3: Update qs-overlay.sh**

Same change — replace lines 6-8 with the sway-aware version from Step 1.

**Step 4: Commit**

```bash
git add quickshell/qs-start.sh quickshell/qs-bar.sh quickshell/qs-overlay.sh
git commit -m "feat(quickshell): sway-aware start scripts"
```

---

### Task 4: Wire sway config to use quickshell

**Files:**
- Modify: `sway/config.d/default:20` (launcher)
- Modify: `sway/config.d/default:47-49` (window rules)
- Modify: `sway/config.d/default:200-202` (project picker bindings)
- Modify: `sway/config.d/default:280-288` (bar section)

**Step 1: Replace rofi launcher with quickshell**

Replace line 20:
```
set $menu rofi -show run 
```
With:
```
set $menu ~/.dotfiles/quickshell/qs-overlay.sh launcher
```

**Step 2: Add quickshell window rules**

After line 49 (`for_window [app_id="waybar"] border none`), add:

```
# Quickshell overlay windows
for_window [title="qs-launcher"] floating enable, border none, move position center
for_window [title="qs-switcher"] floating enable, border none, move position center
for_window [title="qs-projects"] floating enable, border none, move position center
for_window [title="quickshell-notifications"] floating enable, border none, sticky enable
```

**Step 3: Replace project picker bindings**

Replace lines 201-202:
```
bindsym $mod+p exec ~/.local/bin/project-picker
bindsym $mod+Shift+p exec ~/.local/bin/project-picker --new
```
With:
```
bindsym $mod+p exec ~/.dotfiles/quickshell/qs-overlay.sh projects
```

**Step 4: Add switcher keybinding**

After the project binding, add:
```
# Task switcher
bindsym $mod+Tab exec ~/.dotfiles/quickshell/qs-overlay.sh switcher
```

**Step 5: Replace waybar with quickshell**

Replace lines 280-288 (the bar section at the end):
```
# No borders on rofi and waybar
for_window [app_id="rofi"] border none
for_window [app_id="waybar"] border none

#
# Status Bar:
#
exec waybar
```

With:
```
# Quickshell bar + overlay
exec_always ~/.dotfiles/quickshell/qs-start.sh
```

**Step 6: Remove waybar/rofi window rules from earlier in the file**

Remove lines 47-49:
```
# No borders for rofi and waybar
for_window [app_id="rofi"] border none
for_window [app_id="waybar"] border none
```

(These are now replaced by quickshell rules added in Step 2.)

**Step 7: Commit**

```bash
git add sway/config.d/default
git commit -m "feat(sway): replace waybar+rofi with quickshell bar+overlay"
```

---

### Task 5: Update rotz integration (dot.yaml files)

**Files:**
- Modify: `meta-wsl/dot.yaml`
- Modify: `sway/dot.yaml:6-7` (waybar links)
- Modify: `sway/dot.yaml:31` (waybar package)
- Modify: `quickshell/dot.yaml:4-5` (add overlay link)

**Step 1: Add quickshell to meta-wsl**

In `meta-wsl/dot.yaml`, add `quickshell` to the depends list (after `sway`):
```yaml
  - sway
  - quickshell
```

**Step 2: Remove waybar links from sway/dot.yaml**

Remove lines 6-7:
```yaml
    ../waybar/config.jsonc: ~/.config/waybar/config.jsonc
    ../waybar/style.css: ~/.config/waybar/style.css
```

**Step 3: Remove waybar package from sway installs**

In `sway/dot.yaml`, remove `waybar` from the pacman install list (line 31). Change:
```yaml
      sudo pacman -Syu --needed --noconfirm \
        sway \
        foot \
        swaybg \
        xorg-xwayland \
        wl-clipboard \
        waybar
```
To:
```yaml
      sudo pacman -Syu --needed --noconfirm \
        sway \
        foot \
        swaybg \
        xorg-xwayland \
        wl-clipboard
```

**Step 4: Add overlay link to quickshell/dot.yaml**

In `quickshell/dot.yaml`, add the overlay link after the existing config link (after line 5):
```yaml
    overlay: ~/.config/quickshell-overlay
```

**Step 5: Remove rofi config link from sway/dot.yaml**

Remove line 5:
```yaml
    ../i3/config.rasi: ~/.config/rofi/config.rasi
```

Sway no longer uses rofi — quickshell overlay replaces it.

**Step 6: Commit**

```bash
git add meta-wsl/dot.yaml sway/dot.yaml quickshell/dot.yaml
git commit -m "feat(rotz): add quickshell to meta-wsl, remove waybar/rofi from sway"
```

---

### Task 6: Update quickshell/dot.yaml comment

**Files:**
- Modify: `quickshell/dot.yaml:1-2`

**Step 1: Update header comment**

Replace line 1:
```yaml
# Replaces: rofi (launcher), dunst (notifications), polybar (bar)
# Requires: i3 or sway (WM), picom (compositor, X11 only)
```
With:
```yaml
# Replaces: rofi (launcher), dunst (notifications), polybar/waybar (bar)
# Requires: i3 or sway (WM)
```

**Step 2: Commit**

```bash
git add quickshell/dot.yaml
git commit -m "docs(quickshell): update dot.yaml comments for sway support"
```
