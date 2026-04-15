# Alt+W as parallel Alt+Tab trigger (quickshell + i3)

## Problem

Windows has an inconsistent modifier-key model: some window-management shortcuts
use Alt (Alt+Tab, Alt+F4), others use Win (Win+D, Win+E). The long-term direction
is:

- **Win key** → host OS (Windows)
- **Alt key** → nested WM (i3, Sway in WSL/proot)

This idea is the first concrete step in that direction — introduce `Alt+W` as a
second trigger for the window switcher in the quickshell-based i3 setup. The
letter W is easier to reach than Tab and gives a consistent mental model for a
future "Alt+letter" vocabulary across host and guest.

## Scope

**In scope:**
- quickshell switcher on i3 (native Linux + proot Arch on Android)

**Out of scope:**
- Windows host remap (future)
- Sway / WSL (future)
- Any other Alt+letter shortcuts (future)

## Changes

### 1. `quickshell/qs-keymon.py`
- Add X11 keycode `25` (W) to the `INTERESTING` set
- Emits `press 25` / `release 25` alongside existing events
- No other logic changes

### 2. `quickshell/overlay/shell.qml`
In the key handler (around line 252-267), treat W (code 25) the same as Tab
(code 23):

- First press while Alt held → `switcherShow()`
- Subsequent press while switcher visible → `switcherNext()`
- Shift+W while switcher visible → `switcherPrev()` (mirror Shift+Tab)
- Alt release commits focus — unchanged

### 3. `i3/config`
- Add `bindsym Mod1+w exec <same trigger as Mod1+Tab>`
- Add `bindsym Mod1+Shift+w exec <same trigger as Mod1+Shift+Tab>` if the reverse
  binding exists
- Existing Mod1+Tab bindings remain untouched

## Success criteria

- Alt+W opens quickshell switcher on i3 (native + proot)
- Holding Alt and tapping W repeatedly cycles windows
- Alt+Shift+W cycles in reverse
- Alt release focuses selected window
- Alt+Tab continues to work identically (no regression)
