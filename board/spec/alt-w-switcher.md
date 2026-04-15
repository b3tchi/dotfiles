# Alt+W Switcher Implementation Plan

> **For Claude:** Use infinifu:plan-executing, infinifu:plan-subagent, or infinifu:plan-scrum-master to implement this plan.

**Goal:** Add `Alt+W` as a parallel trigger to the existing `Alt+Tab` / `$mod+Tab` quickshell window switcher on i3 (native Linux + proot Arch), without removing the existing Tab bindings.

**Architecture:** The switcher is driven by `qs-keymon.py` — a python-xlib XI2 raw key listener — which emits `press <code>` / `release <code>` events over stdout to `overlay/shell.qml`. The QML side tracks a modifier-held flag and reacts to Tab (code 23). We extend the listener to also emit events for W (code 25), extend the QML handler to treat W identically to Tab, and grab `Mod1+w` in the i3 config so the raw keystroke doesn't leak through to focused applications.

**Tech Stack:** python-xlib (XInputExtension / XI2 raw events), QML (quickshell), i3 config.

---

## Task 1: Extend qs-keymon.py to emit W events

**Files:**
- Modify: `quickshell/qs-keymon.py:20-23`

**Step 1: Update the INTERESTING keycode set and its comment**

Change lines 20-23 from:
```python
# X11 keycodes (not scancodes): 64=Alt_L, 108=Alt_R, 133=Super_L,
# 134=Super_R, 23=Tab. Must stay in sync with the keyMonitor handler
# in quickshell/overlay/shell.qml.
INTERESTING = {64, 108, 133, 134, 23}
```
to:
```python
# X11 keycodes (not scancodes): 64=Alt_L, 108=Alt_R, 133=Super_L,
# 134=Super_R, 23=Tab, 25=W. Must stay in sync with the keyMonitor
# handler in quickshell/overlay/shell.qml.
INTERESTING = {64, 108, 133, 134, 23, 25}
```

**Step 2: Verify the listener emits W events**

Run on the i3 host:
```bash
python3 -u ~/.dotfiles/quickshell/qs-keymon.py
```
Press Alt+W. Expected stdout (order may vary slightly by timing):
```
press 64
press 25
release 25
release 64
```

**Step 3: Commit**

```bash
git add quickshell/qs-keymon.py
git commit -m "feat(quickshell): qs-keymon emits W (code 25) events"
```

---

## Task 2: Handle W in the QML switcher

**Files:**
- Modify: `quickshell/overlay/shell.qml:254-269`

**Step 1: Extend the key handler to treat W like Tab**

Change lines 254-255 from:
```qml
// 23=Tab
var isTab = (code === 23)
```
to:
```qml
// 23=Tab, 25=W — both trigger the switcher
var isSwitcherKey = (code === 23 || code === 25)
```

Then change line 263 from:
```qml
} else if (isTab && action === "press" && root.modHeld) {
```
to:
```qml
} else if (isSwitcherKey && action === "press" && root.modHeld) {
```

No other changes in this block — the `switcherShow()` / `switcherNext()` branch logic stays identical.

**Step 2: Manual verification**

Restart the quickshell session and verify:
- Hold Alt, tap Tab → switcher opens, tap again → cycles (existing, no regression)
- Hold Alt, tap W → switcher opens, tap again → cycles (new)
- Release Alt → focuses the selected window

**Step 3: Commit**

```bash
git add quickshell/overlay/shell.qml
git commit -m "feat(quickshell): Alt+W triggers switcher alongside Alt+Tab"
```

---

## Task 3: Grab Alt+W in i3 so it doesn't leak to focused window

**Files:**
- Modify: `i3/config` (after line 341)

**Step 1: Add parallel `nop` bindings for W**

Immediately after line 341 (`bindsym Mod1+Tab nop`), insert:
```
# Also grab $mod+W / Alt+W — parallel trigger for the quickshell switcher
# (same rationale as Mod1+Tab above: grab so W doesn't leak through to
# the focused window as a typed character).
bindsym $mod+w nop
bindsym Mod1+w nop
```

Note: only the plain combo is grabbed, not `Shift+w`. Shift+W reverse cycling is explicitly out of scope for v1.

**Step 2: Reload i3 and verify no leakage**

```bash
i3-msg reload
```

In a focused terminal running `cat` (so keystrokes echo visibly), press Alt+W:
- Expected: switcher opens, **no "w" character appears** in the terminal
- Without the grab, W would leak through and type "w"

**Step 3: Commit**

```bash
git add i3/config
git commit -m "feat(i3): grab Alt+W for quickshell switcher"
```

---

## Success Criteria

- `Alt+W` opens the quickshell switcher on i3 (native Linux + proot Arch)
- Holding Alt and tapping W repeatedly cycles windows
- Releasing Alt focuses the selected window
- `Alt+Tab` continues to work identically (no regression)
- Alt+W does not leak a "w" character into the focused application

## Out of Scope

- Shift+W reverse cycling (follow-up)
- Windows host PowerToys remap
- Sway / WSL bindings
- Any other Alt+letter vocabulary
