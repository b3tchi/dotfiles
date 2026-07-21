# preview

Localhost file/image preview: a Go daemon (`preview-d`) serves rendered
content over HTTP, a chrome-less webview (`preview-wv`) displays it, and the
`preview` nushell wrapper drives both. Everything goes through the wrapper —
nothing calls the daemon or webview directly (adr0001 nushell-first, adr0003
mandatory-wrapper).

## Commands

```
preview show <path> [-w N]     one-shot: /-rooted daemon + window + send + URL
preview start                  launch the daemon (idempotent)
preview stop                   stop daemon (closes all windows first)
preview status                 daemon health (pid / root / port / started_at)
preview send <path> [-w N]     push a path to window N (default 1)
preview window [N] [--close]   open/close webview window N, docked beside the frame
preview register <addr> [-s N] bind an nvim server addr to a slot (nvim uses this)
```

`/preview <path>` is a Claude Code slash command that runs `preview show`.

## Window controls (image view)

| Action | Control |
|---|---|
| **Fit to window** (default) | automatic — scales up or down, letterboxed |
| **1:1 actual pixels** | click the image, or press `z` / `1` / `space` |
| Back to fit | click / `z` / `1` / `space` again |

In 1:1 mode the view scrolls when the image is larger than the window.

## Docking

Windows tile beside the frame they were launched from — never floating (the
i3 config carries no float rule for `preview-wv`).

**`preview show`** picks the split direction from the image's shape:

| Image shape (w/h) | Dock |
|---|---|
| landscape (> 1.25) | split **above** the frame (top) |
| portrait (< 0.8) | split **left** of the frame |
| square (0.8–1.25) | split **below**, or a **tab** if the frame is < 900px tall |

Only a freshly-opened window docks; an already-open window stays where it is
(moving a live webview would reparent and close it — see below). Re-run after
closing the window (`preview window 1 --close`) to re-dock.

**`preview window`** / **nvim `:PreviewStart`** dock as a fixed **right-side
split** beside the editor (no image shape is known at open time, and
re-docking per file isn't possible).

## Notes

- **Root `/`** — `preview show` roots the daemon at `/` so any absolute path
  previews with no per-call restart. Localhost-only, no auth, single-user.
- **Browser fallback** — the daemon also serves
  `http://127.0.0.1:4200/file/<path>?full`; open it in any browser if the GUI
  window isn't available (e.g. no graphical session).
- **`$PREVIEW_PORT`** overrides the default port `4200`.
- **Reparent hazard** — a mapped `wry`/WebKitGTK window self-closes when i3
  reparents it (split/move after it maps) on xrdp's GL-limited Xorg. All
  docking sets the split *before* the window maps and reorders by moving the
  reparent-safe terminal, never the webview.

## nvim integration

`:PreviewStart` launches the daemon as a child of nvim (so `$NVIM` reaches it
for the reverse `/open` channel), registers this instance's slot, and opens
its docked window. `:PreviewStop` stops the daemon. The preview then follows
the cursor (CursorHold / debounced CursorMoved push the current file).
