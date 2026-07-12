#!/usr/bin/env bash
# smoke.sh — headless Chrome smoke test for akm-graph viewer
#
# Usage: ./smoke.sh [port]
#   Serves akm-graph/static/ + fixture graph.json via python3 http.server
#   Loads the page with ?fixture=graph.json via headless Chrome
#   Asserts document.title == "OK nodes=10"
#
# Requires: python3, Google Chrome (Windows Chrome via WSL path or native Linux)
# Run from: akm-graph/static/ directory, or adjust STATIC_DIR below.

set -euo pipefail

PORT="${1:-9898}"
STATIC_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPECTED_NODES=10   # must match nodes array length in graph.json

# Locate Chrome
CHROME=""
for candidate in \
  "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
  "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
  "google-chrome" \
  "chromium" \
  "chromium-browser"
do
  if command -v "$candidate" &>/dev/null 2>&1 || [ -f "$candidate" ]; then
    CHROME="$candidate"
    break
  fi
done

if [ -z "$CHROME" ]; then
  echo "ERROR: Chrome not found. Checked:"
  echo "  /mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
  echo "  google-chrome, chromium, chromium-browser"
  exit 1
fi

# Start http server
python3 -m http.server "$PORT" --directory "$STATIC_DIR" &>/dev/null &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null' EXIT

# Give server a moment to start
sleep 1

BASE_URL="http://localhost:${PORT}/index.html?fixture=graph.json"
echo "Serving:  $STATIC_DIR"
echo "Chrome:   $CHROME"
echo ""

# ── Stage 1: render assertion, both backends ────────────────────────────────────
# Each engine must build the graph and set document.title = "OK nodes=N". The 2D
# canvas backend (force-graph) renders fine under --disable-gpu; cosmos needs the
# software WebGL path (do NOT add --disable-software-rasterizer).
EXPECTED="OK nodes=${EXPECTED_NODES}"
for BE in force-graph cosmos; do
  URL="${BASE_URL}&backend=${BE}"
  echo "Render [$BE]: $URL"
  DOM=$("$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --virtual-time-budget=15000 \
    --run-all-compositor-stages-before-draw \
    --dump-dom \
    "$URL" 2>/dev/null || true)

  TITLE=$(echo "$DOM" | grep -oP '(?<=<title>)[^<]+' | head -1 || true)
  echo "  document.title = '$TITLE'"
  if [ "$TITLE" = "$EXPECTED" ]; then
    echo "  PASS [$BE]: title matches '$EXPECTED'"
  else
    echo "  FAIL [$BE]: expected '$EXPECTED', got '$TITLE'"
    echo ""
    echo "--- DOM snippet (first 2000 chars) ---"
    echo "${DOM:0:2000}"
    exit 1
  fi
done

# Stages 2–3 below target the cosmos WebGL paint path specifically (tooltip
# signature + 0–255 color normalization), so they pin ?backend=cosmos.
URL="${BASE_URL}&backend=cosmos"

# ── Stage 2: hover tooltip regression (us006 AC2) ───────────────────────────────
# Drives the real cosmos v1 four-arg hover callback via window.__akmGraph and
# asserts the tooltip lands at the cursor (non-NaN left/top) with id/alias/status
# text. The title-only smoke could not catch the signature-mismatch bug; this can.
echo ""
TT_URL="http://localhost:${PORT}/smoke-tooltip.html?fixture=graph.json&backend=cosmos"
echo "Tooltip:  $TT_URL"

TT_DOM=$("$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --virtual-time-budget=15000 \
  --run-all-compositor-stages-before-draw \
  --dump-dom \
  "$TT_URL" 2>/dev/null || true)

TT_TITLE=$(echo "$TT_DOM" | grep -oP '(?<=<title>)[^<]+' | head -1 || true)
TT_RESULT=$(echo "$TT_DOM" | grep -oP '(?<=id="result">)[^<]+' | head -1 || true)
echo "tooltip title  = '$TT_TITLE'"
echo "tooltip result = '$TT_RESULT'"

if [ "$TT_TITLE" = "TOOLTIP_OK" ]; then
  echo "PASS: tooltip positioned at cursor with id/alias/status text"
else
  echo "FAIL: tooltip assertion failed"
  echo ""
  echo "--- tooltip DOM snippet (first 2000 chars) ---"
  echo "${TT_DOM:0:2000}"
  exit 1
fi

# ── Stage 3: color-rendering guard (dotfiles-mry) ───────────────────────────────
# Screenshots the fixture page and counts distinct non-background color buckets.
# cosmos normalizes array colors as [r/255,g/255,b/255,a]; when app.js supplied
# 0–1 floats instead of 0–255 every node rendered ~black and links vanished. The
# title/tooltip stages can't see that — this one can.
#
# Headless WebGL paint timing is racy: some frames capture before cosmos draws
# (an all-dark frame). That flakiness is one-sided — the real 0–1 bug is dark on
# EVERY frame, a timing miss is dark on SOME. So we take up to $MAX_TRIES
# screenshots and pass on the first that clears the threshold; only a genuine
# all-black regression fails all tries.
echo ""
if [[ "$CHROME" == /mnt/c/* ]]; then
  SHOT_ARG='C:\Users\Public\akm-smoke-shot.png'
  SHOT_LNX='/mnt/c/Users/Public/akm-smoke-shot.png'
else
  SHOT_LNX="$(mktemp --suffix=.png)"
  SHOT_ARG="$SHOT_LNX"
fi
echo "Screenshot: $URL"

count_buckets() {
  python3 - "$1" <<'PY' 2>/dev/null || echo 0
import sys, zlib, struct
def load(path):
    d = open(path, 'rb').read(); i = 8; idat = b''; w = h = ct = 0
    while i < len(d):
        ln = struct.unpack('>I', d[i:i+4])[0]; t = d[i+4:i+8]; dt = d[i+8:i+8+ln]
        if t == b'IHDR': w, h, _, ct = struct.unpack('>IIBB', dt[:10])
        elif t == b'IDAT': idat += dt
        elif t == b'IEND': break
        i += 12 + ln
    raw = zlib.decompress(idat); ch = 4 if ct == 6 else 3; st = w * ch
    prev = bytearray(st); pos = 0; rows = []
    for _ in range(h):
        f = raw[pos]; pos += 1; line = bytearray(raw[pos:pos+st]); pos += st
        for x in range(st):
            a = line[x-ch] if x >= ch else 0; b = prev[x]; c = prev[x-ch] if x >= ch else 0
            if f == 1: line[x] = (line[x]+a) & 255
            elif f == 2: line[x] = (line[x]+b) & 255
            elif f == 3: line[x] = (line[x]+((a+b)>>1)) & 255
            elif f == 4:
                p = a+b-c; pa = abs(p-a); pb = abs(p-b); pc = abs(p-c)
                line[x] = (line[x]+(a if (pa<=pb and pa<=pc) else (b if pb<=pc else c))) & 255
        rows.append(line); prev = line
    return ch, b''.join(rows)
ch, px = load(sys.argv[1]); bg = (13, 17, 23); buckets = {}
for p in range(0, len(px), ch):
    r, g, b = px[p], px[p+1], px[p+2]
    if abs(r-bg[0]) + abs(g-bg[1]) + abs(b-bg[2]) > 24:
        buckets[(r//32, g//32, b//32)] = 1
print(len(buckets))
PY
}

MAX_TRIES=5
THRESHOLD=20
BEST=0
for try in $(seq 1 $MAX_TRIES); do
  rm -f "$SHOT_LNX" 2>/dev/null
  "$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --window-size=1000,800 \
    --virtual-time-budget=15000 \
    --run-all-compositor-stages-before-draw \
    --screenshot="$SHOT_ARG" \
    "$URL" 2>/dev/null || true
  n=$(count_buckets "$SHOT_LNX")
  [ "${n:-0}" -gt "$BEST" ] && BEST="$n"
  echo "  try $try: $n color buckets (best $BEST)"
  [ "$BEST" -ge "$THRESHOLD" ] && break
done
rm -f "$SHOT_LNX" 2>/dev/null

echo "best distinct node-color buckets: $BEST (want >= $THRESHOLD over $MAX_TRIES tries)"
if [ "$BEST" -ge "$THRESHOLD" ]; then
  echo "PASS: nodes render in color (not all-black)"
else
  echo "FAIL: max $BEST color buckets across $MAX_TRIES tries — nodes rendering ~black (0–1 vs 0–255 color regression)"
  exit 1
fi

# ── Stage 4: click-isolate regression (dotfiles-xlv) ────────────────────────────
# Drives __akmGraph.selectNode via smoke-select.html and asserts selecting a node
# dims the non-neighbor labels (and clearing undims them).
echo ""
SEL_URL="http://localhost:${PORT}/smoke-select.html?fixture=graph.json"
echo "Select:   $SEL_URL"
SEL_DOM=$("$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --virtual-time-budget=15000 \
  --run-all-compositor-stages-before-draw \
  --dump-dom \
  "$SEL_URL" 2>/dev/null || true)
SEL_TITLE=$(echo "$SEL_DOM" | grep -oP '(?<=<title>)[^<]+' | head -1 || true)
SEL_RESULT=$(echo "$SEL_DOM" | grep -oP '(?<=id="result">)[^<]+' | head -1 || true)
echo "select title  = '$SEL_TITLE'"
echo "select result = '$SEL_RESULT'"
if [ "$SEL_TITLE" = "SELECT_OK" ]; then
  echo "PASS: click-isolate dims non-neighbor labels"
else
  echo "FAIL: click-isolate assertion failed"
  exit 1
fi

# ── Stage 5: category-toggle regression (dotfiles-fj2) ──────────────────────────
# Drives __akmGraph.toggleType via smoke-filter.html and asserts toggling a type
# off hides exactly that type's nodes/labels and toggling it back on restores them.
echo ""
FIL_URL="http://localhost:${PORT}/smoke-filter.html?fixture=graph.json"
echo "Filter:   $FIL_URL"
FIL_DOM=$("$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --virtual-time-budget=15000 \
  --run-all-compositor-stages-before-draw \
  --dump-dom \
  "$FIL_URL" 2>/dev/null || true)
FIL_TITLE=$(echo "$FIL_DOM" | grep -oP '(?<=<title>)[^<]+' | head -1 || true)
FIL_RESULT=$(echo "$FIL_DOM" | grep -oP '(?<=id="result">)[^<]+' | head -1 || true)
echo "filter title  = '$FIL_TITLE'"
echo "filter result = '$FIL_RESULT'"
if [ "$FIL_TITLE" = "FILTER_OK" ]; then
  echo "PASS: category toggle hides/restores nodes by type"
  exit 0
else
  echo "FAIL: category-toggle assertion failed"
  exit 1
fi
