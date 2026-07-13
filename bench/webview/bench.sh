#!/usr/bin/env bash
# webview host benchmark — Servo (servoshell) vs Wry (WebKitGTK) vs QtWebEngine.
# Measures, per engine: cold-start (launch->first GET), whole-page (launch->render
# beacon), and RAM via PSS at 1/2/3 concurrent instances. Content = the akm-graph
# viewer OR a full-screen image. Works on a hardware display or an xrdp software one.
#
# USAGE
#   bench.sh setup                          # fetch servoshell, build wry, write pages
#   bench.sh run   [opts]                   # run the measurements
#   bench.sh all   [opts]                   # setup + run
#   bench.sh clean                          # remove work dir + kill leftovers
#
# OPTS (env or flags)
#   --engines servo,wry,qt      (default all present)
#   --display  :0               X display   (default $DISPLAY or :0)
#   --xauth    PATH             XAUTHORITY  (default ~/.Xauthority; needed for xrdp :10)
#   --content  graph|image      (default graph)
#   --instances N               max concurrent for PSS sweep (default 3)
#   --graph-url URL             akm-graph daemon (default http://localhost:4810/)
#   --port P                    beacon server port (default 4899)
#   --runs N                    timing repeats (default 3)
#   --settle S                  seconds to let each instance settle (default 16)
#
# NOTE Chromium (qt) needs QTWEBENGINE_DISABLE_SANDBOX=1 in most sandboxes; set here.
#      Servo/QtWebEngine binaries are external; the benchmark only downloads/builds
#      into WORK ($XDG_CACHE_HOME/wvbench). Nothing is installed system-wide except
#      qt6-webengine which must be present (pacman -S qt6-webengine).
set -uo pipefail

WORK="${WVBENCH_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/wvbench}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVO_TAG="${SERVO_TAG:-2026-07-12}"   # servo-nightly-builds release tag
PORT=4899; RUNS=3; SETTLE=16; INSTANCES=3; CONTENT=graph
GRAPH_URL="http://localhost:4810/"
DISPLAY_="${DISPLAY:-:0}"; XAUTH="$HOME/.Xauthority"
ENGINES=""

# ---- arg parse ----
CMD="${1:-all}"; shift || true
while [ $# -gt 0 ]; do case "$1" in
  --engines) ENGINES="$2"; shift 2;;
  --display) DISPLAY_="$2"; shift 2;;
  --xauth)   XAUTH="$2"; shift 2;;
  --content) CONTENT="$2"; shift 2;;
  --instances) INSTANCES="$2"; shift 2;;
  --graph-url) GRAPH_URL="$2"; shift 2;;
  --port)    PORT="$2"; shift 2;;
  --runs)    RUNS="$2"; shift 2;;
  --settle)  SETTLE="$2"; shift 2;;
  *) echo "unknown opt $1"; exit 2;;
esac; done

MARK="$WORK/first.txt"; DONE="$MARK.done"
export DISPLAY="$DISPLAY_" XAUTHORITY="$XAUTH" QTWEBENGINE_DISABLE_SANDBOX=1

log(){ printf '%s\n' "$*" >&2; }

# ---------- setup ----------
do_setup(){
  mkdir -p "$WORK/web"
  # servoshell nightly (prebuilt)
  if [ ! -x "$WORK/servo/servoshell" ]; then
    log "fetching servoshell $SERVO_TAG ..."
    curl -fsSL --max-time 300 -o "$WORK/servo.tgz" \
      "https://github.com/servo/servo-nightly-builds/releases/download/$SERVO_TAG/servo-x86_64-linux-gnu.tar.gz"
    tar xzf "$WORK/servo.tgz" -C "$WORK" && rm -f "$WORK/servo.tgz"
  fi
  # wry (WebKitGTK) harness — compiled once
  if [ ! -x "$WORK/wry/target/release/poc-wry" ]; then
    log "building wry harness (cargo, ~2min first time) ..."
    mkdir -p "$WORK/wry/src"
    cat > "$WORK/wry/Cargo.toml" <<EOF
[package]
name="poc-wry"
version="0.0.0"
edition="2021"
[dependencies]
wry="0.45"
tao="0.30"
[profile.release]
opt-level=2
EOF
    cat > "$WORK/wry/src/main.rs" <<'EOF'
use tao::{event::{Event,WindowEvent},event_loop::{ControlFlow,EventLoop},window::WindowBuilder};
use wry::WebViewBuilder;
fn main()->wry::Result<()>{
 let el=EventLoop::new();
 let w=WindowBuilder::new().with_title("wry").build(&el).unwrap();
 let url=std::env::args().nth(1).unwrap_or_else(||"about:blank".into());
 use tao::platform::unix::WindowExtUnix; use wry::WebViewBuilderExtUnix;
 let _v=WebViewBuilder::new_gtk(w.default_vbox().unwrap()).with_url(&url).build()?;
 el.run(move|e,_,cf|{*cf=ControlFlow::Wait; if let Event::WindowEvent{event:WindowEvent::CloseRequested,..}=e{*cf=ControlFlow::Exit;}});
}
EOF
    ( cd "$WORK/wry" && CARGO_TERM_COLOR=never cargo build --release >/dev/null 2>&1 )
  fi
  command -v qml6 >/dev/null || log "WARN: qml6 not found (install qt6-declarative)"
  pkg-config --exists qt6-webengine 2>/dev/null || \
    ls /usr/lib/qt6/qml/QtWebEngine >/dev/null 2>&1 || \
    log "WARN: qt6-webengine QML module missing (pacman -S qt6-webengine)"

  # clean docroot: real viewer assets + a beacon-injected index + an image page
  local static="$HERE/../../akm-graph/static"
  cp "$static/app.js" "$static/force-graph-bundle.js" "$static/cosmos-bundle.js" "$WORK/web/" 2>/dev/null || true
  # inject a /__done beacon (fires when the app sets title "OK nodes=N")
  python3 - "$static/index.html" "$WORK/web/index.html" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
beacon = ('<script>(function(){var iv=setInterval(function(){'
          'if(document.title.indexOf("OK nodes")===0){clearInterval(iv);'
          'fetch("/__done").catch(function(){});}},15);'
          'setTimeout(function(){clearInterval(iv);},20000);})();</script>')
open(dst, "w").write(s.replace("</body>", beacon + "\n</body>"))
PY
  # bundled fixture fallback (10-node) in case the daemon is down at run time
  cp "$static/graph.json" "$WORK/web/graph.json" 2>/dev/null || true
  # image page + a test wallpaper
  cp "${BENCH_IMAGE:-/usr/share/backgrounds/AV_Aca_mountains.jpg}" "$WORK/web/wall.jpg" 2>/dev/null \
    || magick -size 1920x1080 gradient:navy-orange "$WORK/web/wall.jpg" 2>/dev/null
  cat > "$WORK/web/image.html" <<'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>img</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
img{width:100vw;height:100vh;object-fit:cover;display:block}</style></head>
<body><img src="wall.jpg" onload="document.title='OK render';fetch('/__done').catch(function(){})"></body></html>
EOF
  log "setup complete in $WORK"
}

# start beacon server on the clean work docroot ($WORK/web)
start_server(){
  pkill -9 -f "timesrv.py" 2>/dev/null || true; sleep 0.5
  # fresh real graph snapshot as the fixture; keep the bundled fallback if the
  # daemon is down or returns junk (strip trailing slash to avoid //api/graph).
  local snap; snap="$(curl -fsS --max-time 3 "${GRAPH_URL%/}/api/graph" 2>/dev/null)"
  if printf '%s' "$snap" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    printf '%s' "$snap" > "$WORK/web/graph.json"
  fi
  ( cd "$WORK/web" && python3 "$HERE/timesrv.py" "$WORK/web" "$PORT" "$MARK" >/dev/null 2>&1 & )
  sleep 1
}
content_url(){
  if [ "$CONTENT" = image ]; then echo "http://127.0.0.1:$PORT/image.html"
  else echo "http://127.0.0.1:$PORT/index.html?fixture=graph.json"; fi
}

# launch command per engine (takes URL)
launch_cmd(){ case "$1" in
  servo) echo "$WORK/servo/servoshell";;
  wry)   echo "GDK_BACKEND=x11 $WORK/wry/target/release/poc-wry";;
  qt)    echo "__QT__";;   # qt uses a generated qml, handled specially
esac; }
comm_pat(){ case "$1" in
  servo) echo '^servoshell$';;
  wry)   echo '^poc-wry$|^WebKit';;
  qt)    echo '^qml6$|^QtWebEngine';;
esac; }
launch_one(){ # engine url  -> backgrounds an instance, echoes pid
  local e="$1" url="$2"
  if [ "$e" = qt ]; then
    local q; q="$(mktemp "$WORK/qt-XXXX.qml")"
    printf 'import QtQuick\nimport QtQuick.Window\nimport QtWebEngine\nWindow{visible:true;width:800;height:700;title:"qt";color:"#000"\n WebEngineView{anchors.fill:parent;url:"%s"}}\n' "$url" > "$q"
    qml6 "$q" >/dev/null 2>&1 & echo $!
  else
    eval "$(launch_cmd "$e") \"$url\"" >/dev/null 2>&1 & echo $!
  fi
}
killall_engines(){
  pkill -9 -x servoshell 2>/dev/null; pkill -9 -x poc-wry 2>/dev/null; pkill -9 -x qml6 2>/dev/null
  pkill -9 -f WebKitWebProcess 2>/dev/null; pkill -9 -f WebKitNetworkProcess 2>/dev/null
  pkill -9 -f QtWebEngineProcess 2>/dev/null; sleep 2
}

pidset(){ ps -eo pid=,comm= 2>/dev/null | awk -v p="$1" '$2 ~ p {print $1}'; }
pss_of(){ local s=0 pid v; for pid in $(pidset "$1"); do v=$(awk '/^Pss:/{print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null); s=$((s+${v:-0})); done; echo $((s/1024)); }

# ---------- timing: cold-start + whole-page ----------
time_engine(){
  local e="$1" url; url="$(content_url)"; local pat; pat="$(comm_pat "$e")"
  local cg=() wp=()
  for r in $(seq 1 "$RUNS"); do
    rm -f "$MARK" "$DONE"; local t0; t0=$(date +%s.%N)
    local pid; pid=$(launch_one "$e" "$url")
    for _ in $(seq 1 400); do [ -f "$DONE" ] && break; sleep 0.1; done
    if [ -f "$MARK" ]; then cg+=("$(awk -v a="$t0" -v b="$(cat "$MARK")" 'BEGIN{printf "%.2f",b-a}')"); fi
    if [ -f "$DONE" ]; then wp+=("$(awk -v a="$t0" -v b="$(cat "$DONE")" 'BEGIN{printf "%.2f",b-a}')"); fi
    kill -9 "$pid" 2>/dev/null; killall_engines
  done
  local mc mw
  mc=$(printf '%s\n' "${cg[@]}" | sort -n | awk '{a[NR]=$1}END{print (NR?a[int((NR+1)/2)]:"-")}')
  mw=$(printf '%s\n' "${wp[@]}" | sort -n | awk '{a[NR]=$1}END{print (NR?a[int((NR+1)/2)]:"-")}')
  printf '%-6s cold-start %ss | whole-page %ss (median of %d)\n' "$e" "$mc" "$mw" "$RUNS"
}

# ---------- RAM: PSS at 1..N concurrent ----------
pss_engine(){
  local e="$1" url; url="$(content_url)"; local pat; pat="$(comm_pat "$e")"
  local row="$e PSS:"
  for n in $(seq 1 "$INSTANCES"); do
    launch_one "$e" "$url" >/dev/null
    sleep "$SETTLE"
    row="$row  ${n}x=$(pss_of "$pat")"
  done
  killall_engines
  echo "$row  MiB"
}

do_run(){
  start_server
  local list="${ENGINES:-servo,wry,qt}"
  echo "### webview bench — content=$CONTENT display=$DISPLAY_ ($(date -u +%FT%TZ 2>/dev/null || echo now))"
  echo "-- timing --"
  IFS=, read -ra ES <<< "$list"; for e in "${ES[@]}"; do time_engine "$e"; done
  echo "-- ram (PSS, concurrent) --"
  for e in "${ES[@]}"; do pss_engine "$e"; done
  killall_engines
}

do_clean(){ killall_engines; pkill -9 -f "timesrv.py" 2>/dev/null; rm -rf "$WORK"; echo "cleaned $WORK"; }

case "$CMD" in
  setup) do_setup;;
  run)   do_run;;
  all)   do_setup; do_run;;
  clean) do_clean;;
  *) sed -n '2,40p' "$0"; exit 2;;
esac
