#!/usr/bin/env bash
# test-bar-font-render.sh — kwi3-55l.18: Bar.qml's tab text renders
# photometrically identical to i3kwin chrome/Decoration.qml's titlebar text,
# not merely at the same nominal font.pixelSize.
#
# Jan, testing 3392 (real use): "the bar's font looks slightly bigger than
# the other fonts (kwi3 window titlebars, terminal)". kwi3-55l.16's own
# investigation (routed here first) ruled out a pointSize/pixelSize unit bug
# and a family/weight mismatch — both Bar.qml and i3kwin/chrome/Decoration.qml
# source font.family/font.pixelSize from the SAME core/defaults.js
# FONT_FAMILY/FONT_PIXEL_SIZE, with no point/pixel conversion anywhere
# between them — and named one real, then-UNCONFIRMED difference: Bar.qml's
# focused-tab Text sets `renderType: Text.NativeRendering`; Decoration.qml's
# equivalent Text sets no renderType at all (QtQuick's own default,
# Text.QtRendering).
#
# CONFIRMED here by measurement, not by re-guessing: the two render at
# IDENTICAL logical metrics (Text.contentWidth/contentHeight — QFontMetrics
# does not care which renderType paints the glyphs) but different PAINTED
# pixels. Rendering the identical string/family/pixelSize/colour/weight pair
# through a real X11 (xcb) Qt backend and diffing the painted pixels
# (Item.grabToImage + ImageMagick's mean luminance) shows NativeRendering
# paints measurably MORE ink than QtRendering on Jan's exact focused palette
# (#fdf6e3 text on #152024, bold) — a real, if small, photometric gap, which
# is what "looks slightly bigger" is - not a logical width or DPI bug (the
# live session's own /proc/<pid>/environ carries no QT_SCALE_FACTOR/
# QT_FONT_DPI difference between the two processes either).
#
# THIS MUST RUN UNDER A REAL Xvfb/xcb DISPLAY, not the `offscreen` QPA
# platform: the same NativeRendering-vs-QtRendering comparison run under
# `offscreen` measures byte-identical images (Qt's software backend does not
# distinguish the two paths at all there) and would never fail no matter
# what Bar.qml sets - a test built on it would just always pass. So this is
# NOT one of test-kwi3-backend.sh's/test-mode-bar.sh's offscreen phases; it
# needs Xvfb the same way test-kwi3-backend.sh's PHASE 6 (a real PanelWindow)
# does.
#
# The fix pins Bar.qml's `nativeRender` property to Text.QtRendering,
# matching the chrome exactly. This test reads BOTH sides live off disk
# rather than restating a constant: Bar.qml's actual current
# `readonly property int nativeRender: <expr>` RHS is spliced verbatim into
# the "actual" probe, and it FAILS LOUDLY (not silently passing) if
# Decoration.qml ever starts setting an explicit renderType of its own — the
# reference side changing out from under this comparison is exactly the kind
# of drift a hardcoded literal here would hide.
#
# usage: quickshell/test-bar-font-render.sh
# env:   XVFB= QUICKSHELL= IM_BIN=   (default: Xvfb, quickshell, magick|convert)
#        TEST_DISPLAY=:96
#        KWI3_REPO=      kwi3 checkout providing i3kwin/chrome/Decoration.qml
#                        (default: ~/.local/src/kwi3, matching
#                        test-kwi3-backend.sh's own convention)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BAR_QML="$SCRIPT_DIR/config/Bar.qml"

XVFB="${XVFB:-Xvfb}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
DPY="${TEST_DISPLAY:-:96}"
KWI3_REPO="${KWI3_REPO:-$HOME/.local/src/kwi3}"
DECO_QML="$KWI3_REPO/i3kwin/chrome/Decoration.qml"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
scenario() { printf '\n[%s]\n' "$1"; }

TMP="/tmp/qs-barfont-test.$$"
CFG="$TMP/cfg"
RUN="$TMP/run"

cleanup() {
  [ -n "${QS_PID:-}" ]   && kill -- -"$QS_PID"   2>/dev/null
  [ -n "${QS_PID:-}" ]   && kill "$QS_PID"       2>/dev/null
  sleep 0.3
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID"     2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

for tool in "$XVFB" "$QUICKSHELL"; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "SKIP: $tool not found (XVFB=/QUICKSHELL= to override)"; exit 77; }
done
IM_BIN="$(command -v magick || command -v convert || true)"
[ -n "$IM_BIN" ] || { echo "SKIP: ImageMagick (magick/convert) not found"; exit 77; }
[ -r "$BAR_QML" ]  || { echo "FATAL: $BAR_QML missing" >&2; exit 1; }
[ -r "$DECO_QML" ] || { echo "SKIP: $DECO_QML missing (KWI3_REPO=$KWI3_REPO)"; exit 77; }

mkdir -p "$TMP" "$CFG" "$RUN"
chmod 700 "$RUN"

# ---- read Bar.qml's ACTUAL current renderType for the focused-tab text ----
NATIVE_EXPR="$(sed -n 's/^[[:space:]]*readonly property int nativeRender: \(.*\)$/\1/p' "$BAR_QML" | head -1)"
[ -n "$NATIVE_EXPR" ] || { echo "FATAL: could not find Bar.qml's 'readonly property int nativeRender: ...' line — it may have been renamed; update this test's extraction pattern." >&2; exit 1; }

# ---- prove the reference side's own assumption: Decoration.qml sets no
#      renderType anywhere, i.e. relies on QtQuick's implicit default. If
#      that ever stops being true this test's "reference" style is stale. ----
if grep -q 'renderType' "$DECO_QML"; then
  echo "FATAL: $DECO_QML now sets an explicit renderType somewhere — this test's reference assumption (implicit QtQuick default) is stale. Update the reference Text below to match, deliberately, before trusting this result." >&2
  exit 1
fi

dpy_up() { # <display>
  [ -e "/tmp/.X11-unix/X${1#:}" ] && return 0
  grep -q "@/tmp/\.X11-unix/X${1#:}\$" /proc/net/unix 2>/dev/null
}

cat > "$CFG/shell.qml" <<QMLEOF
import Quickshell
import QtQuick

ShellRoot {
  FloatingWindow {
    id: win
    implicitWidth: 400
    implicitHeight: 200
    visible: true
    // Jan's real focused palette (kwi3/config.js palette.focused /
    // i3/colors.conf): #fdf6e3 text on #152024, both Bar.qml's focused tab
    // and Decoration.qml's focused titlebar use exactly this pair.
    color: "#152024"

    Text {
      id: actualText
      objectName: "actualText"
      x: 10; y: 10
      text: "asahi 01234567"
      color: "#fdf6e3"
      font.family: "Iosevka"
      font.pixelSize: 16
      font.bold: true
      renderType: ${NATIVE_EXPR}
    }

    Text {
      id: referenceText
      objectName: "referenceText"
      x: 10; y: 80
      text: "asahi 01234567"
      color: "#fdf6e3"
      font.family: "Iosevka"
      font.pixelSize: 16
      font.bold: true
      // No renderType set — this IS Decoration.qml's own style, verbatim
      // (proven above: Decoration.qml sets renderType nowhere).
    }

    Component.onCompleted: Qt.callLater(function() {
      actualText.grabToImage(function(r) {
        r.saveToFile("$RUN/actual.png")
        referenceText.grabToImage(function(r2) {
          r2.saveToFile("$RUN/reference.png")
          console.log("READY")
        })
      })
    })
  }
}
QMLEOF

scenario "bring up display"
"$XVFB" "$DPY" -screen 0 400x300x24 -nolisten tcp >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
i=0
while ! dpy_up "$DPY"; do
  i=$((i + 1))
  [ "$i" -ge 100 ] && { echo "FATAL: Xvfb did not come up on $DPY" >&2; cat "$TMP/xvfb.log" >&2; exit 1; }
  sleep 0.1
done
pass "xvfb-up"

scenario "render both styles"
env -u WAYLAND_DISPLAY -u I3SOCK -u KWI3SOCK \
  QT_QPA_PLATFORM=xcb DISPLAY="$DPY" HOME="$RUN" XDG_CACHE_HOME="$RUN/cache" \
  XDG_RUNTIME_DIR="$RUN" \
  timeout 10 "$QUICKSHELL" -p "$CFG" >"$TMP/qs.log" 2>&1 &
QS_PID=$!
i=0
while [ ! -f "$RUN/reference.png" ]; do
  i=$((i + 1))
  [ "$i" -ge 100 ] && { echo "FATAL: quickshell never produced reference.png" >&2; cat "$TMP/qs.log" >&2; exit 1; }
  sleep 0.1
done
[ -s "$RUN/actual.png" ] && pass "actual-png-written" || fail "actual-png-written" "non-empty file" "missing/empty"
[ -s "$RUN/reference.png" ] && pass "reference-png-written" || fail "reference-png-written" "non-empty file" "missing/empty"

mean_of() { "$IM_BIN" "$1" -colorspace Gray -format '%[fx:mean]' info: 2>/dev/null; }
ACTUAL_MEAN="$(mean_of "$RUN/actual.png")"
REFERENCE_MEAN="$(mean_of "$RUN/reference.png")"

scenario "photometric parity (actual == reference, within tolerance)"
DELTA="$(awk -v a="$ACTUAL_MEAN" -v r="$REFERENCE_MEAN" 'BEGIN{d=a-r; if(d<0)d=-d; printf "%.6f", d}')"
# The measured gap between NativeRendering and QtRendering on this exact
# palette/size is ~0.003 (mean luminance, 0..1 scale) under a real xcb
# backend; two renders of the SAME style measure bit-identical (delta
# 0.000000). 0.0015 sits at half that real gap: it fails on the bug and
# passes once Bar.qml's nativeRender genuinely matches the reference style.
EPS=0.0015
if awk -v d="$DELTA" -v e="$EPS" 'BEGIN{exit !(d<=e)}'; then
  pass "actual-matches-reference-luminance (delta=$DELTA actual=$ACTUAL_MEAN reference=$REFERENCE_MEAN nativeExpr=$NATIVE_EXPR)"
else
  fail "actual-matches-reference-luminance" "delta<=$EPS" "delta=$DELTA actual=$ACTUAL_MEAN reference=$REFERENCE_MEAN nativeExpr=$NATIVE_EXPR"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
