# Focus-dim: Dialogs Stay Bright — Implementation Plan

> **For Claude:** Use infinifu:plan-scrum-master (automated) or infinifu:plan-supervised (user reviews each batch) to implement this plan.

**Goal:** When a focused window is a quickshell `qs-` popup, Rofi, or any floating window, the dim cut-out follows it (window bright, rest dimmed). When a non-floating ignored class (the quickshell bar) is "focused", or there is no focus, the screen fully dims. Behavior identical on X11/i3 and Wayland/sway.

**Bd epic:** `dotfiles-56r`

**Predecessor:** `dotfiles-0xd` (focus-dim base, merged).

**Architecture:** Extend the existing focus-decision logic in two files (`quickshell/qs-focus-dim.py`, `quickshell/config/FocusDimWayland.qml`). Add a "is floating" signal to the focus walker so floating windows bypass the class-based ignore. Remove `rofi` from the ignore list. Invert the `qs-` title branch from ignore to focus-target.

**Tech Stack:** Python 3 + GTK3 + cairo (X11), Quickshell QML + `swaymsg` (Wayland). No new dependencies.

---

## Conventions

- Quickshell config in `quickshell/config/` (symlinked via rotz). Helper scripts in `quickshell/`.
- Verification is **manual visual confirmation** — no automated overlay test framework. Synthetic tree-walk tests for the Python `walk` / `should_ignore` are allowed and encouraged (the dotfiles-0xd T3 implementer used them).
- Commits use Conventional Commits: `feat(quickshell):`, `fix(quickshell):`, `refactor(quickshell):`.
- Anti-patterns inherited from dotfiles-0xd remain in force (see `board/done/focus-dim.md` once archived, otherwise `board/ready/focus-dim.md`):
  - No silent exception swallow — `print(..., file=sys.stderr, flush=True)` in `except` paths.
  - No Xlib at module top-level.
  - No `--no-verify` on commits. Pre-commit hooks must pass.
  - No TODO without follow-up bd task.
  - Do not introduce a new dispatch path or new files — modify in place.

## File tree (changes only)

```
quickshell/
├── qs-focus-dim.py            (modified — walker + should_ignore)
└── config/
    └── FocusDimWayland.qml    (modified — applyContainer + walker)
```

---

## Task 1: X11 — floating + qs- titled treated as focusable, rofi removed

Update the Python overlay so floating windows and `qs-` titled windows become cut-out targets. Remove `Rofi`/`rofi` from `IGNORE_CLASSES`.

**Files:**
- Modify: `quickshell/qs-focus-dim.py`
- Create: `quickshell/test_qs_focus_dim_dialogs.py` (one-shot synthetic walk test)

**Step 1: Write the failing synthetic walk test**

The codebase has no test harness, but `qs-focus-dim.py` is plain Python — we can drive `walk` + `should_ignore` directly. Create `quickshell/test_qs_focus_dim_dialogs.py`:

```python
"""One-shot synthetic walk tests for qs-focus-dim dialog handling.
Run: python3 quickshell/test_qs_focus_dim_dialogs.py
"""
import importlib.util, pathlib, sys, types

# Stub gi/cairo before import so the GTK overlay code doesn't try to draw.
sys.modules.setdefault("gi", type(sys)("gi"))
sys.modules["gi"].require_version = lambda *a, **k: None
gi_repo = types.ModuleType("gi.repository")
for n in ("Gtk", "Gdk", "GLib"):
    setattr(gi_repo, n, types.SimpleNamespace())
sys.modules["gi.repository"] = gi_repo
sys.modules["cairo"] = types.SimpleNamespace()

spec = importlib.util.spec_from_file_location(
    "qsd", pathlib.Path(__file__).parent / "qs-focus-dim.py"
)
qsd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qsd)


def make_leaf(cls="", title="", fullscreen=0):
    return {
        "focused": True,
        "window": 1,
        "window_properties": {"class": cls, "instance": cls},
        "name": title,
        "rect": {"x": 100, "y": 100, "width": 800, "height": 600},
        "deco_rect": {"height": 0},
        "fullscreen_mode": fullscreen,
        "nodes": [],
        "floating_nodes": [],
    }


def wrap_floating(leaf):
    return {"nodes": [], "floating_nodes": [
        {"nodes": [leaf], "floating_nodes": []}
    ]}


def wrap_tiled(leaf):
    return {"nodes": [leaf], "floating_nodes": []}


def run():
    # Case 1: regular tiled window — focusable
    qsd.focus_rect = None
    qsd._compute_focus_rect(wrap_tiled(make_leaf(cls="Firefox", title="example.com - Mozilla Firefox")))
    assert qsd.focus_rect is not None, "regular tiled window should produce focus_rect"

    # Case 2: floating qs- dialog — focusable
    qsd.focus_rect = None
    qsd._compute_focus_rect(wrap_floating(make_leaf(cls="quickshell", title="qs-overlay-projects")))
    assert qsd.focus_rect is not None, "floating qs- dialog must be focusable"

    # Case 3: floating Rofi — focusable (rofi removed from IGNORE_CLASSES)
    qsd.focus_rect = None
    qsd._compute_focus_rect(wrap_floating(make_leaf(cls="Rofi", title="rofi")))
    assert qsd.focus_rect is not None, "floating rofi must be focusable now"

    # Case 4: bar (class quickshell, tiled, no qs- title) — IGNORED
    qsd.focus_rect = "PLACEHOLDER"
    qsd._compute_focus_rect(wrap_tiled(make_leaf(cls="quickshell", title="")))
    assert qsd.focus_rect is None, "tiled quickshell bar must remain ignored"

    # Case 5: qs- titled tiled window — focusable via title prefix
    qsd.focus_rect = None
    qsd._compute_focus_rect(wrap_tiled(make_leaf(cls="anything", title="qs-anything")))
    assert qsd.focus_rect is not None, "qs- titled tiled window should be focusable"

    # Case 6: fullscreen wins over focusable
    qsd.focus_rect = "PLACEHOLDER"
    qsd._compute_focus_rect(wrap_floating(make_leaf(cls="quickshell", title="qs-foo", fullscreen=1)))
    assert qsd.focus_rect is None, "fullscreen wins over focusable"

    # Case 7: no focused window — full dim
    qsd.focus_rect = "PLACEHOLDER"
    qsd._compute_focus_rect({"nodes": [], "floating_nodes": []})
    assert qsd.focus_rect is None, "no focus → full dim"

    print("All 7 synthetic walk cases passed.")


if __name__ == "__main__":
    run()
```

**Step 2: Run the test — must FAIL**

Run: `python3 quickshell/test_qs_focus_dim_dialogs.py`
Expected: `AttributeError: module 'qsd' has no attribute '_compute_focus_rect'` — fails because the helper does not exist yet. This proves the test is wired before any implementation.

**Step 3: Refactor `qs-focus-dim.py` to apply the new rule + expose a pure decision helper**

In `quickshell/qs-focus-dim.py`:

1. Change `IGNORE_CLASSES`:
   ```python
   IGNORE_CLASSES = {'quickshell'}  # rofi removed — caught by floating rule
   ```

2. Update `should_ignore` to take `in_floating`:
   ```python
   def should_ignore(c, in_floating):
       """Return True if c should be treated as 'no focused window' (full dim)."""
       if in_floating:
           return False
       props = c.get('window_properties', {})
       cls = props.get('class', '')
       instance = props.get('instance', '')
       title = c.get('name', '')
       if title.startswith('qs-'):
           return False
       return cls in IGNORE_CLASSES or instance in IGNORE_CLASSES
   ```

3. Update `walk` to track floating-subtree descent:
   ```python
   def walk(node, parents, in_floating):
       if node.get('focused') and node.get('window'):
           return node, parents, in_floating
       for child in node.get('nodes', []):
           r = walk(child, parents + [node], in_floating)
           if r:
               return r
       for child in node.get('floating_nodes', []):
           r = walk(child, parents + [node], True)
           if r:
               return r
       return None
   ```

4. Extract the decision logic into a pure `_compute_focus_rect(tree)` at module scope so the test can call it without GTK:
   ```python
   def _compute_focus_rect(tree):
       """Update module-level focus_rect from an i3 tree dict. Pure function (no GTK)."""
       global focus_rect
       result = walk(tree, [], False)
       if not result:
           focus_rect = None
           return
       leaf, parents, in_floating = result
       if should_ignore(leaf, in_floating) or leaf.get('fullscreen_mode', 0) > 0:
           focus_rect = None
           return
       r = leaf.get('rect', {})
       deco_h = leaf.get('deco_rect', {}).get('height', 0)
       in_tabbed = any(p.get('layout') in ('tabbed', 'stacked') for p in parents)
       direct_in_tabbed = parents and parents[-1].get('layout') in ('tabbed', 'stacked')
       if in_tabbed and not direct_in_tabbed:
           deco_h = 0
       focus_rect = (
           r.get('x', 0),
           r.get('y', 0) - deco_h,
           r.get('width', 0),
           r.get('height', 0) + deco_h,
       )
   ```

5. Replace `refresh_focused._do` body so it calls `_compute_focus_rect`:
   ```python
   def refresh_focused():
       def _do():
           try:
               tree = json.loads(
                   subprocess.check_output(
                       ['i3-msg', '-t', 'get_tree'], timeout=2
                   ).decode()
               )
               _compute_focus_rect(tree)
               GLib.idle_add(_redraw_all)
           except Exception as exc:
               print(f"qs-focus-dim: refresh_focused: {exc}",
                     file=sys.stderr, flush=True)
       threading.Thread(target=_do, daemon=True).start()
   ```

The previous inline `walk` and inline decision logic (the entire `if not result: ... else: ...` block currently in `refresh_focused._do`) are now removed — replaced by the single call to `_compute_focus_rect(tree)`. Don't leave the old code around as a fallback.

**Step 4: Run the test — must PASS**

Run: `python3 quickshell/test_qs_focus_dim_dialogs.py`
Expected output: `All 7 synthetic walk cases passed.`

Also run `python3 -m py_compile quickshell/qs-focus-dim.py` to catch syntax issues. Expected: silent success.

**Step 5: Commit**

```bash
chmod +x quickshell/test_qs_focus_dim_dialogs.py   # mirror qs-focus-dim.py executable bit
git add quickshell/qs-focus-dim.py quickshell/test_qs_focus_dim_dialogs.py
git commit -m "feat(quickshell): focus-dim treats floating + qs- titled windows as focusable"
```

The test file is kept in tree as a regression net — the walker has now seen two rounds of edits (dotfiles-0xd T3 + this task) and is the most fragile part of the file.

**Success criteria (must all pass before review):**
- [ ] `python3 quickshell/test_qs_focus_dim_dialogs.py` → all 7 cases pass
- [ ] `python3 -m py_compile quickshell/qs-focus-dim.py` → exits 0
- [ ] `grep -E "^from Xlib|^import Xlib" quickshell/qs-focus-dim.py` returns empty
- [ ] `grep -nE "except[^:]*:[[:space:]]*pass" quickshell/qs-focus-dim.py` returns empty (no silent swallows)
- [ ] `IGNORE_CLASSES` contains exactly `{'quickshell'}` — no `Rofi`/`rofi`
- [ ] `should_ignore` signature is `(c, in_floating)`
- [ ] Old inline `walk` inside `refresh_focused._do` is gone (replaced by `_compute_focus_rect` call)

Deferred to user (live X11/i3): `$mod+p` opens qs-overlay → cut-out around overlay; rofi cut-out; bar still ignored; fullscreen still full-dim.

---

## Task 2: Wayland — floating + qs- titled treated as focusable, rofi removed

Mirror Task 1 in `FocusDimWayland.qml`. Sway represents floating windows in their workspace's `floating_nodes` array; the walker needs to track that descent.

**Files:**
- Modify: `quickshell/config/FocusDimWayland.qml`

**Step 1: Verify sway floating tree shape (~5 minutes, before editing)**

Canonical sway tree shape (verified against sway IPC docs):

- Workspace nodes contain `nodes` (tiled children) and `floating_nodes` (floating children).
- A node inside `floating_nodes` typically has `type: "floating_con"` and either represents the window directly or contains it as a `con` child.
- Leaf con: `type: "con"`, with `app_id` (Wayland-native), `window_properties.class` (XWayland), and a `pid`.

The walker marks `in_floating = true` when descending into `floating_nodes`. This is the same propagation strategy as the i3 Python path (Task 1) — keeps logic symmetric.

If a live sway session is available, sanity-check with:
```bash
swaymsg -t get_tree | jq '.. | select(.type? == "floating_con") | {name, app_id, type}' | head
```
Expected: at least one entry per visible floating window. If unavailable, proceed using the documented shape — the synthetic guarantee is "anything reachable only via `floating_nodes` is in_floating".

**Step 2: Modify `applyContainer` to accept `in_floating`**

Current signature (line 202): `function applyContainer(c) { ... }`. Update to:

```qml
readonly property var ignoreAppIds: ["quickshell"]  // rofi removed

function applyContainer(c, in_floating) {
    var appId = c.app_id || ""
    var cls = (c.window_properties || {}).class || ""
    var title = c.name || ""

    if (c.fullscreen_mode > 0) {
        hasFocus = false
        return
    }
    // Floating windows and qs- titled windows bypass class-based ignore
    if (!in_floating && !title.startsWith("qs-")) {
        if (ignoreAppIds.indexOf(appId) >= 0 || ignoreAppIds.indexOf(cls) >= 0) {
            hasFocus = false
            return
        }
    }
    var r = c.rect || {}
    var decoH = (c.deco_rect || {}).height || 0
    fx = r.x || 0
    fy = (r.y || 0) - decoH
    fw = r.width || 0
    fh = (r.height || 0) + decoH
    hasFocus = (fw > 0 && fh > 0)
}
```

Control-flow order matters: fullscreen first (always wins), then the floating/qs- bypass, then the class-ignore check.

**Step 3: Update `focusScan.onExited` walker to track `in_floating`**

Current walker body (lines 183–194):
```qml
function walk(node) {
    if (found) return
    if (node.focused && node.pid) {
        dimOverlay.applyContainer(node)
        found = true
        return
    }
    var children = (node.nodes || []).concat(node.floating_nodes || [])
    for (var i = 0; i < children.length; i++) walk(children[i])
}
walk(tree)
```

Replace with:
```qml
function walk(node, in_floating) {
    if (found) return
    if (node.focused && node.pid) {
        dimOverlay.applyContainer(node, in_floating)
        found = true
        return
    }
    var tiled = node.nodes || []
    for (var i = 0; i < tiled.length; i++) walk(tiled[i], in_floating)
    var floating = node.floating_nodes || []
    for (var j = 0; j < floating.length; j++) walk(floating[j], true)
}
walk(tree, false)
```

**Step 4: Update the event-driven call sites (`swaySubscribe`)**

The event-driven path (`swaySubscribe.onRead` handlers around lines 94 and 97) currently calls `applyContainer(e.container)` directly. The single-container event payload does not include parent-walk info, so the safest fix is to trigger a fresh `focusScan` instead of calling `applyContainer` directly.

For each `dimOverlay.applyContainer(e.container)` call inside `swaySubscribe.onRead`, replace with:
```qml
focusScan.running = true
```

Rationale: `focusScan` walks the whole tree with `in_floating` propagation, so the floating state is always correct. The cost is one extra `swaymsg -t get_tree` per event, which is the same cost the i3 path already pays via the always-`get_tree` `refresh_focused`. Performance is acceptable for human-scale focus events.

Also add a subscription to the `floating` window event so toggling tiled↔floating updates the overlay. Inside `swaySubscribe`'s parsed-event branches, add `else if (e.change === "floating")` that also triggers `focusScan.running = true`.

**Step 5: Mechanical syntax check + grep regression checks**

Without a live sway session, agents cannot start quickshell. Run these greps in the worktree:

```bash
grep -n 'ignoreAppIds' quickshell/config/FocusDimWayland.qml
# Expected exactly one hit, content: ["quickshell"]  (no "rofi")

grep -n 'applyContainer' quickshell/config/FocusDimWayland.qml
# Expected: declaration with (c, in_floating); plus 1 call site in focusScan walk.
# applyContainer should NOT appear inside swaySubscribe blocks anymore.

grep -nE '\b(bw|br|bc|inset)\b' quickshell/config/FocusDimWayland.qml
# Expected empty (regression check from dotfiles-0xd T7 anti-pattern).

grep -n 'Component.onCompleted' quickshell/config/FocusDimWayland.qml
# Expected empty (regression check from dotfiles-0xd T6 anti-pattern).

grep -n 'walk(tree' quickshell/config/FocusDimWayland.qml
# Expected: walk(tree, false)  — starts with in_floating=false at root
```

If all greps pass, behavior verification is deferred to the user at runtime.

**Step 6: Commit**

```bash
git add quickshell/config/FocusDimWayland.qml
git commit -m "feat(quickshell): focus-dim Wayland — floating + qs- titled focusable"
```

**Success criteria:**
- [ ] All five greps in Step 5 return the expected results.
- [ ] `applyContainer` signature is `(c, in_floating)`.
- [ ] Both `walk` recursion sites pass `in_floating` correctly (`true` into `floating_nodes`, propagated otherwise).
- [ ] `swaySubscribe` event branches trigger `focusScan.running = true` instead of calling `applyContainer` directly.
- [ ] `floating` window event also triggers `focusScan`.

Deferred to user (live sway session): all behavioral scenarios from the matrix in Task 3.

---

## Task 3: End-to-end verification matrix

No code changes. Walk the matrix on each platform actually available. Mark cells `✓` / `✗` / `~` and file follow-up bd issues for `✗` cells.

**Files:** spec markdown only, and only if failures are observed.

**Step 1: Restart overlays**

```bash
# X11 / i3 — dispatcher will respawn within 2s
pkill -f qs-focus-dim.py

# Wayland / sway
pkill -x quickshell; sleep 1; $HOME/.dotfiles/quickshell/qs-start.sh &
```

**Step 2: Walk the matrix**

| Trigger | Platform | Expected | Result |
|---|---|---|---|
| `$mod+p` opens qs-overlay | X11/i3 | Cut-out around overlay; rest dimmed |  |
| `$mod+p` opens qs-overlay | Wayland/sway | Cut-out around overlay; rest dimmed |  |
| `$mod+d` opens rofi | X11/i3 | Cut-out around rofi; rest dimmed |  |
| `$mod+d` opens rofi | Wayland/sway | Cut-out around rofi; rest dimmed |  |
| Focus a normal tiled window | both | Cut-out around it (regression) |  |
| Toggle floating (`$mod+shift+space`) on a tiled window | both | Cut-out follows new geometry |  |
| Click on quickshell bar | both | Bar bright; full screen dim (regression) |  |
| Fullscreen toggle (`$mod+f`) | both | Full dim while fullscreen (regression) |  |
| Multi-monitor: dialog on monitor 0 | X11 | Cut-out on monitor 0; monitor 1 full dim |  |

**Step 3: For each `✗` cell**

Append a "Known issues" section to this spec and file a follow-up:
```bash
bd create --title "focus-dim-dialogs: <failure>" --type bug --priority 2
```
Do not patch in-band — failures get a separate fix loop.

**Step 4: Commit verification notes (only if failures observed)**

```bash
git add board/ready/focus-dim-dialogs-bright.md   # or current spec location
git commit -m "docs(focus-dim-dialogs): record verification notes"
```

**Success criteria:**
- [ ] Every cell has `✓`, `✗`, or `~`.
- [ ] Every `✗` has a corresponding bd issue.
- [ ] No regressions: tiled-window cut-out, bar bright, fullscreen full-dim still pass.

---

## Out of scope (deferred)

- Configurable dim opacity (still hardcoded 30%).
- Animated fade between dim states.
- Per-app override list (force-dim or force-bright a specific app).
- Stacking brightness (parent window lit, dialog brighter).
- HiDPI fractional-scale fix (inherited from dotfiles-0xd).
- Wayland multi-monitor floating-coord fix (inherited).
