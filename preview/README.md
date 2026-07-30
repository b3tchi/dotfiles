# preview

Localhost file/image preview: a Go daemon (`preview-d`) serves rendered
content over HTTP, a native Qt Quick client (`qml6 PreviewView.qml`)
displays it, and the `preview` nushell wrapper drives both. Everything goes
through the wrapper — nothing calls the daemon or the QML client directly
(adr0001 nushell-first, adr0003 mandatory-wrapper).

The QML client replaces an earlier wry/WebKitGTK window host (`preview-wv`,
sp013) — retired in sp022 once every tier it served had a QML equivalent.
See "Removed limitations" below for what that retirement bought.

## Commands

```
preview show <path> [-w N]     one-shot: /-rooted daemon + window + send + URL
preview start                  launch the daemon (idempotent)
preview stop                   stop daemon (closes all windows first)
preview status                 daemon health (pid / root / port / started_at)
preview send <path> [-w N]     push a path to window N (default 1)
preview window [N] [--close]   open/close preview window N, docked beside the frame
preview register <addr> [-s N] bind an nvim server addr to a slot (nvim uses this)
```

`/preview <path>` is a Claude Code slash command that runs `preview show`.

## Render tiers

Every previewed path is classified server-side (`GET /preview<N>`'s `type`
field) and the QML client dispatches it to one of two Loaders — a native
tier or a lazy web tier — never both live at once:

| `type` | Tier | How it renders |
|---|---|---|
| `image` | native | Qt `Image`, fit<->1:1 toggle |
| `svg` | native | Qt `Image` (vector), same toggle — reached by `.d2` sources only (see below) |
| `md` | native | server-rendered HTML text, `?native` payload |
| `code` | native | chroma-highlighted HTML text, `?native` payload |
| `video` | native | Qt multimedia `VideoOutput` |
| `none` | native | fallback message (no path set / unclassifiable) |
| `html` | web (lazy) | `WebEngineView` loading `/file/<path>?native` (raw bytes) |
| `akm` | web (lazy) | `WebEngineView` loading `/file/<path>?slot=<N>` (cross-origin akm-graph-d iframe embed, adr0009) |
| `stl` | web (lazy) | `WebEngineView` loading `/file/<path>` (the kept orbit-viewer page + `/static/stl-viewer.js`) |

The `svg` type is produced by **`.d2` sources only** — `classifyPath`'s
`isD2Ext` branch, whose payload is the compiled+flattened svg relayed from
[[ft002]]'s `/api/svg`. A checked-in `.svg` file is *not* svg-typed: no
extension test claims it, so it falls through to chroma's lexer match and
renders as `code` (syntax-highlighted XML). Measured E2E, sp022 Task 9.

`import QtWebEngine` lives in exactly one file (`WebTier.qml`) and its
`WebEngineView` is only instantiated the first time a web-tier type is
actually shown — the ~240 MiB WebEngine process cost is paid at most once
per window, never for a purely native-tier session (sp022 Tasks 4-5).
Switching *within* the web tier (e.g. `html` -> `akm` -> `stl`) is a plain
URL navigation on the same live engine, never a relaunch.

## Window controls (image view)

| Action | Control |
|---|---|
| **Fit to window** (default) | automatic — scales up or down, letterboxed |
| **1:1 actual pixels** | click the image, or press `z` / `1` / `space` |
| Back to fit | click / `z` / `1` / `space` again |

In 1:1 mode the view scrolls when the image is larger than the window.

## Docking

Windows tile beside the frame they were launched from — never floating.

**X11 only.** Both entry points capture the launching frame with
`active-window-id`, which is `xdotool getactivewindow` — so under a Wayland
compositor (the `meta-wsl-sway` session) there is no frame id, and *no dock
runs at all*: the window still opens and renders every tier natively, it just
lands wherever the compositor puts it. The `swaymsg [pid=…]` criterion in
`window-criteria` is therefore unreachable from `show`/`window` today.
Measured E2E on real sway 1.12 with `xwayland disable`, sp022 Task 9
(dotfiles-8ryw).

**`preview show`** picks the split direction from the image's shape:

| Image shape (w/h) | Dock |
|---|---|
| landscape (> 1.25) | split **above** the frame (top) |
| portrait (< 0.8) | split **left** of the frame |
| square (0.8–1.25) | split **below**, or a **tab** if the frame is < 900px tall |

Every `show` call re-docks — a window already open just moves to match the
new image's shape (top → left → below → …), the same window, same pid,
never closed and reopened. There is no "first open only" limitation.

**`preview window`** / **nvim `:PreviewStart`** dock as a fixed **right-side
split** beside the editor (no image shape is known at open time).

## Window identity (pid-based)

The wrapper resolves an already-open preview window by **pid**, not by WM
class or title (sp022 Task 6). `qml6`'s WM_CLASS is the Qt runtime's own
identity — shared by every `qml6`-hosted app in the repo (d2-view included)
— so a class or title criterion was never viable for this engine the way it
was for the old dedicated `preview-wv` binary. sway exposes a native
`[pid=…]` window criterion; i3 does not, so the i3 path resolves the pid to
an X11 window id via `xdotool` first and matches `[id=…]`. Each slot's pid
is tracked in its own pidfile, verified against `/proc/<pid>/cmdline` before
any signal is sent (never trust a bare pid — recycling is real).

## Notes

- **Root `/`** — `preview show` roots the daemon at `/` so any absolute path
  previews with no per-call restart. Localhost-only, no auth, single-user.
- **Browser fallback** — the daemon also serves
  `http://127.0.0.1:4200/file/<path>?full`; open it in any browser if the GUI
  window isn't available (e.g. no graphical session).
- **`$PREVIEW_PORT`** overrides the default port `4200`.
- **Docking mechanism** — the preview window is a native `qml6` process,
  which survives being split/moved/reparented after it has already mapped
  (unlike the old WebKitGTK-based host, which self-closed on reparent). So
  docking marks the launching frame, then moves the *preview window itself*
  to sit beside that mark — live or freshly spawned, the same recipe either
  way, which is what makes re-docking a live window possible.

## Removed limitations (sp022 — retiring the wry host)

The wry/WebKitGTK host (`preview-wv`, sp013) is gone: the whole
`preview-webview` Rust crate, its static shell page and client script, and
the daemon's `handlePreviewShell` route are deleted (sp022 Task 8). What
that bought:

- **No self-close on reparent** — the wry window used to close itself when
  the WM reparented it mid-dock; the QML client tolerates it (see "Docking
  mechanism" above).
- **No second toolchain** — building this project no longer needs `cargo` /
  WebKitGTK dev packages alongside `go`; a stale `~/.local/bin/preview-wv`
  from an older install is cleaned up by `rotz install preview`.
- **No class-based window matching** — see "Window identity" above; this
  was a forced change (qml6's shared WM_CLASS), not optional, but it also
  removed the old assumption that this daemon's window was the only thing
  ever wearing that class.
- **One process for every tier** — the old host was WebKitGTK end to end;
  now only the three tiers that genuinely need a web engine (`html`/`akm`/
  `stl`) pay for one, lazily, and the rest render as native Qt Quick items.

**Reverse channel note (ft005 retro):** [[sp008]] Task 10 shipped a
`postMessage` listener in the old shell's client script as the akm/d2
reverse channel's browser-side half. [[adr0007]] later superseded it for
the akm case with a server-side daemon-to-daemon channel (backend resolves
the selection, `POST /open` routes to the owning nvim by slot) and kept the
`postMessage` listener only as a dormant fallback "until a same-shell case
justifies it." That listener's only host page no longer exists after this
task — it is deleted along with the rest of the old shell, not migrated.
Nothing regresses: the live reverse channel has been the adr0007 path since
[[sp009]], and the browser-side listener was never more than a dormant
fallback that no caller ever exercised.

## nvim integration

`:PreviewStart` launches the daemon as a child of nvim (so `$NVIM` reaches it
for the reverse `/open` channel), registers this instance's slot, and opens
its docked window. `:PreviewStop` stops the daemon. The preview then follows
the cursor (CursorHold / debounced CursorMoved push the current file).
