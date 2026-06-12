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

URL="http://localhost:${PORT}/index.html?fixture=graph.json"
echo "Serving:  $STATIC_DIR"
echo "URL:      $URL"
echo "Chrome:   $CHROME"
echo ""

# Run headless Chrome, dump DOM
# NOTE: do NOT add --disable-software-rasterizer — cosmos needs software WebGL
DOM=$("$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --virtual-time-budget=15000 \
  --run-all-compositor-stages-before-draw \
  --dump-dom \
  "$URL" 2>/dev/null || true)

# Extract <title>
TITLE=$(echo "$DOM" | grep -oP '(?<=<title>)[^<]+' | head -1 || true)
echo "document.title = '$TITLE'"

EXPECTED="OK nodes=${EXPECTED_NODES}"
if [ "$TITLE" = "$EXPECTED" ]; then
  echo "PASS: title matches '$EXPECTED'"
else
  echo "FAIL: expected '$EXPECTED', got '$TITLE'"
  echo ""
  echo "--- DOM snippet (first 2000 chars) ---"
  echo "${DOM:0:2000}"
  exit 1
fi

# ── Stage 2: hover tooltip regression (us006 AC2) ───────────────────────────────
# Drives the real cosmos v1 four-arg hover callback via window.__akmGraph and
# asserts the tooltip lands at the cursor (non-NaN left/top) with id/alias/status
# text. The title-only smoke could not catch the signature-mismatch bug; this can.
echo ""
TT_URL="http://localhost:${PORT}/smoke-tooltip.html?fixture=graph.json"
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
  exit 0
else
  echo "FAIL: tooltip assertion failed"
  echo ""
  echo "--- tooltip DOM snippet (first 2000 chars) ---"
  echo "${TT_DOM:0:2000}"
  exit 1
fi
