# Focus-dim: dialogs stay bright with rest dimmed

**Bd epic:** `dotfiles-56r`
**Predecessor:** `dotfiles-0xd` (focus-dim overlay base implementation)

## Goal

When a dialog window (`qs-` titled quickshell popup or any floating window) is focused, the dim cut-out tracks the dialog so it stays bright while the rest of the screen dims. Today such windows are in the ignore list and the entire screen dims (including the dialog), which makes dialogs harder to read instead of more focused.

## Motivation

`$mod+p` runs `qs-overlay.sh projects`, opening a quickshell popup with title `qs-*`. After landing dotfiles-0xd, that popup appears dimmed along with the rest of the screen. The user expected the popup to be the highlighted region. The same friction applies to Rofi and any other floating dialog.

## Success Criteria

- [ ] `$mod+p` (qs-overlay) → cut-out around overlay window, rest of screen dimmed
- [ ] Rofi (`$mod+d`) → cut-out around rofi window, rest of screen dimmed
- [ ] Any floating window (i3 `floating_nodes` / sway `type == "floating_con"`) → cut-out around it
- [ ] Bar (class `quickshell`, not floating, no `qs-` title) → still ignored, no cut-out, screen behavior unchanged
- [ ] Fullscreen window → full dim (unchanged)
- [ ] No focused window → full dim (unchanged)
- [ ] X11 and Wayland behave identically

## Approach

Approach 1 ("two-list flip", chosen):

- Remove `Rofi`/`rofi` from `IGNORE_CLASSES` (Python) and `ignoreAppIds` (QML); keep `quickshell` (bar still ignored).
- Remove the `title.startswith("qs-")` → ignore branch; invert it: `qs-`-titled windows are *focusable* cut-out targets.
- Add a "in floating subtree" signal to the focus walker:
  - **i3 (Python):** when descending into `floating_nodes`, mark child as `in_floating=True`; pass through to `should_ignore`.
  - **sway (QML):** check `c.type === "floating_con"` (or scan tree path for a floating ancestor) inside `applyContainer` and treat as focusable.
- Decision rule (after walk finds focused leaf):
  1. If fullscreen → `focus_rect = None` (unchanged).
  2. If `in_floating` OR `title.startswith("qs-")` → focusable (cut-out around it), bypass class-based ignore.
  3. Else if class/instance in IGNORE_CLASSES → `focus_rect = None`.
  4. Else → cut-out around leaf (unchanged).

## File scope

- `quickshell/qs-focus-dim.py` — Python X11 path: modify `should_ignore`, `walk`, `refresh_focused`.
- `quickshell/config/FocusDimWayland.qml` — sway path: modify `applyContainer`, `focusScan.walk`.
- No new files. No changes to `FocusDim.qml`, `shell.qml`.

## Anti-patterns (carry forward from dotfiles-0xd)

- ❌ No silent exception swallow — `print(..., file=sys.stderr, flush=True)` in `except` paths.
- ❌ No Xlib at module top-level.
- ❌ No `--no-verify` on commits.
- ❌ No TODO without a follow-up bd task.
- ❌ Do not introduce a new ignore list — reuse `IGNORE_CLASSES` / `ignoreAppIds` with `rofi` removed.
- ❌ Do not couple to specific dialog titles (e.g., `qs-overlay-projects`) — the prefix `qs-` is the contract, plus floating-subtree presence.

## Open questions (deferred to spec/refinement)

- Sway's `type == "floating_con"` exact JSON shape and where to detect floating ancestry — verify against a live `swaymsg -t get_tree` dump.
- Multi-monitor: a floating dialog spanning two monitors should still cut out correctly using the existing 4-rect math (already handled by the off-monitor fallback).
- Does i3 ever nest floating containers (`floating_nodes` of a `floating_con`)? Walker must handle that case so `in_floating` propagates.

## Out of scope

- Configurable dim opacity (still hardcoded 30%).
- Animated transitions when dialog opens/closes.
- Per-app override list (e.g., a way to force-dim a specific dialog).
- Stacking dim levels (e.g., parent window also lit, dialog brighter).
- HiDPI scaling fix.
- Wayland multi-monitor coord fix (inherited limitation from dotfiles-0xd).

## Verification (manual, same constraints as dotfiles-0xd)

No automated test harness for the overlay. Verification matrix at spec time:

| Trigger | Platform | Expected |
|---|---|---|
| `$mod+p` (qs-overlay) | X11/i3 | Cut-out around overlay window |
| `$mod+p` (qs-overlay) | Wayland/sway | Cut-out around overlay window |
| `$mod+d` (rofi) | X11/i3 | Cut-out around rofi |
| `$mod+d` (rofi) | Wayland/sway | Cut-out around rofi |
| Focus normal tiled window | both | Cut-out around it (regression check) |
| Float a tiled window | both | Cut-out follows floating geometry |
| Click bar | both | Bar stays bright, full screen dim (regression check) |
| Fullscreen toggle | both | Full dim while fullscreen (regression check) |
