# webview host benchmark

Compares **Servo** (servoshell), **Wry** (WebKitGTK) and **QtWebEngine** as hosts
for the akm-graph viewer / sp008 file previews — render, RAM (RSS + PSS at 1/2/3
concurrent instances), and load speed (cold-start + whole-page) — across content
types (JS graph vs static image) and displays (hardware vs xrdp software render).

Results + analysis: `docs/notes/lab/poc012.md` (consolidates poc007–011).

## Run

```bash
bench/webview/bench.sh all                       # setup + run, graph, current $DISPLAY
bench/webview/bench.sh all --content image       # fullscreen image instead
bench/webview/bench.sh run --display :10 --xauth ~/.Xauthority   # xrdp software render
bench/webview/bench.sh run --engines wry,qt --instances 3 --runs 3
bench/webview/bench.sh clean                      # kill leftovers + remove work dir
```

`setup` fetches servoshell (prebuilt nightly, ~134MB), builds a ~30-line Wry/tao
harness (needs `webkit2gtk-4.1`), and writes the beacon pages into
`$XDG_CACHE_HOME/wvbench`. QtWebEngine needs `qt6-webengine` installed
(`pacman -S qt6-webengine`). The akm-graph daemon should be running on
`--graph-url` (default `http://localhost:4810/`) for the real-graph fixture;
otherwise a bundled 10-node fixture is used.

## How it measures

- **Beacon server** (`timesrv.py`) serves the real viewer assets with a `/__done`
  beacon injected — the app pings it when `document.title` becomes `OK nodes=N`
  (render kicked off). Cold-start = launch→first GET; whole-page = launch→beacon.
- **PSS** (`/proc/PID/smaps_rollup`) is summed across each engine's processes at
  1..N concurrent instances — the honest metric (shared `.so` pages divided among
  sharers), unlike RSS which double-counts them.

Everything runs on-machine; nothing is installed except the one-time
`qt6-webengine` dependency.
