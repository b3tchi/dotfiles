# quickshell refactor — shared components + per-platform profiles

**Status:** idea, deferred (2026-04-12)
**Reference commit:** `90c70ea` (ships the current split architecture working)

## Goal

Refactor `quickshell/` into shared QML components under `quickshell/components/`, with multiple `profile-*/shell.qml` entry points composing them differently per target. Same idiom as the `meta-linux` / `meta-proot` / `meta-termux` rotz meta-packages — one set of parts, many assemblies.

## Shape

```
quickshell/
  components/                   # shared QML — single source of truth
    Bar.qml                     # PanelWindow (moved from config/)
    Overlay.qml                 # floating Window + switcher/launcher/projects UI
    MruTracker.qml              # i3 focus subscriber + focusHistory list
    WindowScanner.qml           # i3 get_tree reader
    Keymon.qml                  # Process wrapper around qs-keymon.py
    NotificationTicker.qml      # future — factored from Bar

  profile-full/                 # native Linux, one process everything
    shell.qml                   # instantiates bar + overlay in one ShellRoot

  profile-split-bar/            # conservative fallback, bar only
    shell.qml

  profile-split-overlay/        # conservative fallback, overlay only
    shell.qml

  profile-termux/               # potential future (bar-only, no WM)
    shell.qml
```

`quickshell/dot.yaml` links the right profile's `shell.qml` to `~/.config/quickshell/shell.qml` via handlebars (`whoami.distro`, `env.HOME`).

## Why

The current split (`config/shell.qml` + `overlay/shell.qml`) runs as two Qt processes: **~456 MB total RSS**, of which ~175 MB is the second quickshell runtime.

The historical "X11 can't do two PanelWindows" blocker (commits `0d0e6e4`, `d89fd70`) **no longer applies** — our overlay is a plain `Window`, not a second `PanelWindow`. The split was preserved defensively after a past proot issue, but the conditions that caused it have changed.

The profile mechanism lets native Linux benefit from the merge while preserving a rollback path if proot or Termux:X11 hits version-specific quirks on an older Qt/Quickshell build.

## Two-phase plan

### Phase 1 — component extraction (low-risk, no behavior change)

Factor state out of `overlay/shell.qml` into reusable components under `quickshell/components/`. Both existing entry points (`config/shell.qml`, `overlay/shell.qml`) still work, just importing the components instead of inlining logic.

Commit at the end of Phase 1: refactor only, same runtime shape, same process count, identical behavior.

### Phase 2 — profile split + merged build

1. Create `profile-full/shell.qml` that composes bar + overlay in one `ShellRoot`
2. Update `qs-start.sh` to launch one quickshell instance
3. Rewire `qs-overlay.sh` IPC calls to target the merged process (no `-p` flag)
4. Template `quickshell/dot.yaml` to link per-platform
5. Keep `profile-split-*` entries as proot insurance
6. Measure RSS before/after to confirm ~175 MB saving

## Risks to verify before merging

- **QML id collisions** — both current files use `id: root` at `ShellRoot` level; merge needs unique ids or careful scoping.
- **IpcHandler targets** — already distinct (`launcher`, `switcher`, `projects`), no conflict.
- **Window coexistence** — one `PanelWindow` (Bar) + one plain `Window` (Overlay) in a single process. Unblocked on current Quickshell but should be smoke-tested on proot before shipping there.
- **NotificationServer ownership** — only one `NotificationServer` can exist per process, not a concern since there's already only one in `config/shell.qml`.

## Cost estimate

~300 lines of moved code, 5–6 new component files, 2–4 new profile entries. Phase 1 alone is maybe an hour of careful cut-and-paste + smoke tests. Phase 2 is where the real validation work lives.
