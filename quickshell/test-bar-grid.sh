#!/usr/bin/env bash
# test-bar-grid.sh — dotfiles-rlnv: the Bar's RIGHT side (stats, VOL:/KBL:
# pairs, tray, bell, clock/date) sits on kwi3's character-cell grid.
#
# Same rule as the mode strip (dotfiles-puoh, test-mode-bar.sh): under kwi3
# every segment's x/width is a whole number of cells (content rounded UP,
# separators as cell widths), the right edge is one cell in from the bar's
# edge. Tray and bell icons are the titlebar icon's size (moduleH - 2 = 19 at
# 8x21, sourceSize = side) packed at pitch moduleH; the whole-cell rounding is
# over the WHOLE tray block, not per icon (Jan): block = ceil(n*H/W)*W, the
# spare split to its two ends (8x21: n=1 24, n=2 48, n=3 64, n=4 88). The bell
# is its own segment (icon + count, rounded up to cells). With no grid
# (cellW 0: i3/sway) nothing changes: tray slot 18 / icon 14, bell 14 + count
# + 4, clock margin 8, Text widths = implicitWidth.
#
# Host: the REAL config/Bar.qml under Xvfb. Kwi3Grid is a real singleton fed by
# Kwi3Client, so Bar exposes `cellW`/`cellH` (default: the grid's module) and
# `trayModel` (default: SystemTray.items) as test hooks; the host sets them.
# The tray is fed two ways. (1) A FAKE, production-shaped: a Quickshell
# ScriptModel (a QAbstractListModel exposing `values`, the same shape as
# SystemTray.items' UntypedObjectModel - and, like it, NO `.length`; asserted)
# holding JS objects {icon, activate, secondaryActivate}. A plain JS array has
# `.length`, and once hid a Bar that counted with it (dotfiles-rlnv rejection
# #1: trayCount undefined and trayRow.x NaN in production). (2) The REAL
# SystemTray.items, on a PRIVATE session bus (a dbus-daemon started here, never
# the user's), where quickshell becomes the StatusNotifierWatcher and python3-gi
# StatusNotifierItems register and vanish: 0, 2, 3, then 2 again. Without
# dbus-daemon / python3 gi that arm is a loud SKIP, never a pass.
#
# usage: quickshell/test-bar-grid.sh
# env:   XVFB= QUICKSHELL= TEST_DISPLAY=:9301 BAR_QML=<Bar.qml to test>
#        GEOM_OUT=<file> write the raw no-grid geometry (parity diffing)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/config/Common"
BAR_QML="${BAR_QML:-$SCRIPT_DIR/config/Bar.qml}"
XVFB="${XVFB:-Xvfb}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
DPY="${TEST_DISPLAY:-:9301}"
TMP="/tmp/qs-bargrid-test.$$"
CFG="$TMP/cfg"; RUN="$TMP/run"; CCH="$TMP/cache"; CASES="$TMP/cases.txt"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
a2() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
scenario() { printf '\n[%s]\n' "$1"; }
case_of() { sed -n "s/^CASE $1 //p" "$CASES" | head -1; }

cleanup() {
  [ -n "${BAR_PID:-}" ]  && kill -- -"$BAR_PID" 2>/dev/null
  [ -n "${BAR_PID:-}" ]  && kill "$BAR_PID" 2>/dev/null
  sleep 0.3
  for p in ${SNI_PIDS:-}; do kill "$p" 2>/dev/null; done
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  [ -n "${DBUS_PID:-}" ] && kill "$DBUS_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

dpy_up() { # both socket namespaces, see test-mode-bar.sh (dotfiles-4ai2)
  [ -e "/tmp/.X11-unix/X${1#:}" ] && return 0
  grep -q "@/tmp/\.X11-unix/X${1#:}\$" /proc/net/unix 2>/dev/null
}

SKIPS=""
skip() { SKIPS="$SKIPS
  SKIP  $1"; printf '  SKIP  %s\n' "$1"; }

for tool in "$XVFB" "$QUICKSHELL" jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool not found" >&2; exit 1; }
done
[ -r "$BAR_QML" ] || { echo "FATAL: $BAR_QML missing" >&2; exit 1; }
mkdir -p "$TMP" "$CFG" "$RUN" "$CCH" "$TMP/pbin"; chmod 700 "$RUN"
ln -s "$COMMON_DIR" "$CFG/Common"
ln -s "$BAR_QML" "$CFG/Bar.qml"

# sandboxed PATH: a stub i3-msg/swaymsg (no workspaces, subscriptions idle) and
# the coreutils the Bar's probes shell out to (they no-op harmlessly).
SLEEP_BIN="$(command -v sleep)"
for t in sh cat sleep tr awk df grep sed cut head; do
  src="$(command -v "$t")" && ln -sf "$src" "$TMP/pbin/$t"
done
cat > "$TMP/pbin/i3-msg" <<STUB
#!/bin/sh
case "\$1" in -t) case "\$2" in get_workspaces) printf '[]'; exit 0 ;; subscribe) exec "$SLEEP_BIN" 300 ;; esac ;; esac
exit 0
STUB
chmod +x "$TMP/pbin/i3-msg"; ln -sf "$TMP/pbin/i3-msg" "$TMP/pbin/swaymsg"
printf '#!/bin/sh\nexec %s 300\n' "$SLEEP_BIN" > "$TMP/feed.sh"; chmod +x "$TMP/feed.sh"

cat > "$CFG/shell.qml" <<'HOST'
import Quickshell
import Quickshell.Io
import Quickshell.Services.SystemTray
import QtQuick
import "./Common"

ShellRoot {
  id: host
  property int cw: 0
  property int ch: 0
  property int tn: 3
  property bool real: false
  // production-shaped fake: a QAbstractListModel with `values` and no `.length`
  ScriptModel { id: fakeTray; values: host.allTray.slice(0, host.tn) }
  readonly property var allTray: [
    { icon: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 8'%3E%3Crect width='8' height='8' fill='red'/%3E%3C/svg%3E",
      activate: function () {}, secondaryActivate: function () {} },
    { icon: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 8'%3E%3Crect width='8' height='8' fill='blue'/%3E%3C/svg%3E",
      activate: function () {}, secondaryActivate: function () {} },
    { icon: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 8'%3E%3Crect width='8' height='8' fill='green'/%3E%3C/svg%3E",
      activate: function () {}, secondaryActivate: function () {} },
    { icon: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 8'%3E%3Crect width='8' height='8' fill='black'/%3E%3C/svg%3E",
      activate: function () {}, secondaryActivate: function () {} } ]
  function emit(n, p) { console.log("CASE " + n + " " + p) }
  function rootOf(w) { return (w && w.contentItem) ? w.contentItem : w }
  function findByName(item, name) {
    if (!item) return null
    var kids = item.children
    for (var i = 0; i < kids.length; i++) {
      if (kids[i].objectName === name) return kids[i]
      var f = findByName(kids[i], name)
      if (f) return f
    }
    return null
  }
  function findAll(item, name, out) {
    if (!item) return
    var kids = item.children
    for (var i = 0; i < kids.length; i++) {
      if (kids[i].objectName === name) out.push(kids[i])
      findAll(kids[i], name, out)
    }
  }
  function g(it) { return { x: it.x, w: it.width } }
  function kids(row) {
    var out = []
    for (var i = 0; i < row.children.length; i++) {
      var c = row.children[i]
      if (!c.visible || c.width <= 0) continue   // Repeater itself has no width
      out.push({ n: c.objectName || c.text || "", x: c.x, w: c.width,
                 iw: (c.text !== undefined ? c.implicitWidth : null) })
    }
    return out
  }
  function dump(name) {
    var r = rootOf(bar)
    var rs = findByName(r, "rightSide"), cd = findByName(r, "clockDate")
    var vol = findByName(r, "volSeg"), kbd = findByName(r, "kbdSeg")
    var slots = [], icons = []
    findAll(r, "traySlot", slots); findAll(r, "trayIcon", icons)
    var tb = findByName(r, "trayBlock"), trow = findByName(r, "trayRow")
    var bell = findByName(r, "bellSlot"), bi = findByName(r, "bellIcon"), bc = findByName(r, "bellCount")
    var sep = findByName(r, "traySep")
    var o = {
      real: host.real, modelHasLength: bar.trayModel.length !== undefined,
      trayCount: bar.trayCount, trayRowXFinite: isFinite(trow.x),
      traySepVisible: sep ? sep.visible : null, traySepW: sep ? sep.width : null,
      traySepText: sep ? sep.text : null,
      cell: host.cw, H: host.ch,
      rs: g(rs), cd: g(cd), parentW: cd.parent.width,
      rsKids: kids(rs), cdKids: kids(cd),
      vol: { g: g(vol), l: g(findByName(vol, "volLabel")), v: g(findByName(vol, "volValue")) },
      kbd: kbd.visible ? { g: g(kbd), l: g(findByName(kbd, "kbdLabel")), v: g(findByName(kbd, "kbdValue")) } : null,
      trayBlock: g(tb), trayRowX: trow.x, trayN: host.tn,
      tray: slots.map(function (s, i) {
        return { x: s.x, w: s.width, ix: icons[i].x, iw: icons[i].width, ih: icons[i].height,
                 sw: icons[i].sourceSize.width, sh: icons[i].sourceSize.height } }),
      bell: { g: g(bell), ix: bi.x, iw: bi.width, ih: bi.height, sw: bi.sourceSize.width,
              cx: bc.x, cw: bc.width, ci: bc.implicitWidth }
    }
    emit(name, JSON.stringify(o))
  }
  IpcHandler {
    target: "bargrid"
    function setgrid(w: int, h: int, n: int): void { host.cw = w; host.ch = h; host.tn = n }
    function setreal(on: bool): void { host.real = on }
    function trayslots(): string {   // live slot count, for polling SNI arrivals
      var s = []; host.findAll(host.rootOf(bar), "traySlot", s); return String(s.length)
    }
    function dumpc(name: string): void { host.dump(name) }
    function bye(): void { Quickshell.exit(0) }
  }
  Bar {
    id: bar
    screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    cellW: host.cw
    cellH: host.ch
    trayModel: host.real ? SystemTray.items : fakeTray
    notifCount: 3
    netVal: "1.5M"
    cpuVal: "12"
    ramVal: "47"
    diskVal: "63"
    volVal: "50"
    batVal: "83"
    batStatus: "Discharging"
  }
}
HOST

QS_BIN="$(command -v "$QUICKSHELL")"
# A private session bus for the whole run: quickshell's SystemTray becomes the
# StatusNotifierWatcher HERE, never on the user's bus.
REAL_OK=1
command -v dbus-daemon >/dev/null 2>&1 || { REAL_OK=0; skip "real SNI arm: dbus-daemon not found"; }
if [ "$REAL_OK" = 1 ] && ! python3 -c 'from gi.repository import Gio, GLib' >/dev/null 2>&1; then
  REAL_OK=0; skip "real SNI arm: python3 gi (Gio) not found"
fi
if [ "$REAL_OK" = 1 ]; then
  DBUS_OUT="$(dbus-daemon --session --fork --nopidfile --print-address=1 --print-pid=1)" || DBUS_OUT=""
  DBUS_ADDR="$(printf '%s\n' "$DBUS_OUT" | sed -n 1p)"; DBUS_PID="$(printf '%s\n' "$DBUS_OUT" | sed -n 2p)"
  [ -n "$DBUS_ADDR" ] && [ -n "$DBUS_PID" ] || { echo "FATAL: dbus-daemon present but did not start" >&2; exit 1; }
else
  DBUS_ADDR="unix:path=$TMP/no-bus"   # still never the user's bus
fi
# One StatusNotifierItem per process: owns a name, exports /StatusNotifierItem
# and registers with the watcher (retrying until quickshell has claimed it).
cat > "$TMP/sni-item.py" <<'SNIPY'
import os, sys, warnings
warnings.simplefilter("ignore")
from gi.repository import Gio, GLib
tag = sys.argv[1]
XML = """<node><interface name="org.kde.StatusNotifierItem">
<property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
<property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
<property name="WindowId" type="i" access="read"/><property name="IconName" type="s" access="read"/>
<property name="IconPixmap" type="a(iiay)" access="read"/><property name="OverlayIconName" type="s" access="read"/>
<property name="AttentionIconName" type="s" access="read"/><property name="ItemIsMenu" type="b" access="read"/>
<property name="Menu" type="o" access="read"/><property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
</interface></node>"""
PROPS = {"Category": GLib.Variant("s", "ApplicationStatus"), "Id": GLib.Variant("s", "qs-test-" + tag),
  "Title": GLib.Variant("s", tag), "Status": GLib.Variant("s", "Active"), "WindowId": GLib.Variant("i", 0),
  "IconName": GLib.Variant("s", ""),
  "IconPixmap": GLib.Variant("a(iiay)", [(8, 8, bytes([255, 255, 0, 0]) * 64)]),
  "OverlayIconName": GLib.Variant("s", ""), "AttentionIconName": GLib.Variant("s", ""),
  "ItemIsMenu": GLib.Variant("b", False), "Menu": GLib.Variant("o", "/NO_DBUSMENU"),
  "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", [], "", ""))}
def on_call(c, snd, path, iface, method, params, inv):
    print("SNI %s %s" % (tag, method), flush=True)
    inv.return_value(None)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
bus.register_object("/StatusNotifierItem", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0],
                    on_call, lambda c, s, p, i, prop: PROPS[prop], None)
name = "org.kde.StatusNotifierItem-%d-1" % os.getpid()
bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
              GLib.Variant("(su)", (name, 4)), None, 0, -1, None)
def reg():
    try:
        bus.call_sync("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                      "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
                      GLib.Variant("(s)", (name,)), None, 0, 2000, None)
        print("SNI %s registered" % tag, flush=True)
        return False
    except GLib.Error:
        return True
if reg():
    GLib.timeout_add(200, reg)
GLib.MainLoop().run()
SNIPY
"$XVFB" "$DPY" -screen 0 1280x300x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 50); do dpy_up "$DPY" && break; sleep 0.1; done
dpy_up "$DPY" || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

# SWAYSOCK set (bogus) so isSway is true and the KBL: pair renders; the stub
# swaymsg keeps every wm probe inert.
setsid env DISPLAY="$DPY" PATH="$TMP/pbin" SWAYSOCK="$TMP/none.sock" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
    XDG_CONFIG_HOME="$CFG" XDG_RUNTIME_DIR="$RUN" XDG_CACHE_HOME="$CCH" \
    QS_LAYER_FEED="$TMP/feed.sh" QS_BAR_DENSITY=full \
    "$QS_BIN" -p "$CFG" >"$TMP/qs.out" 2>&1 &
BAR_PID=$!
ipc() { env XDG_CONFIG_HOME="$CFG" XDG_RUNTIME_DIR="$RUN" XDG_CACHE_HOME="$CCH" \
          "$QUICKSHELL" ipc --pid "$BAR_PID" "$@" 2>/dev/null; }
for i in $(seq 1 60); do
  [ "$(ipc show | grep -c bargrid)" -gt 0 ] && { UP=1; break; }; sleep 0.5
done
if [ -z "${UP:-}" ]; then
  fail "bar host exposed the 'bargrid' IPC target" "a target" "none"; tail -30 "$TMP/qs.out" >&2
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi
sleep 1
: > "$CASES"
run() { # <name> <cellW> <cellH> <trayN>
  ipc call bargrid setgrid "$2" "$3" "$4" >/dev/null; sleep 0.6
  ipc call bargrid dumpc "$1" >/dev/null; sleep 0.3
}
run g8   8 21 3
run g10  10 20 3
for n in 0 1 2 3 4; do run "g8n$n" 8 21 "$n"; run "g10n$n" 10 20 "$n"; done
run g8b  8 21 3        # second visit: layout settles back, not order dependent
run nogrid 0 0 3

# ---- the REAL SystemTray.items (the production model) on the private bus ----
SNI_PIDS=""
sni_add() { # <tag>: start one SNI item process
  env DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" python3 "$TMP/sni-item.py" "$1" >"$TMP/sni-$1.log" 2>&1 &
  SNI_PIDS="$SNI_PIDS $!"; eval "SNI_$1=$!"
}
sni_wait() { # <n>: poll until the bar lays out exactly n tray slots (<= 10s)
  for i in $(seq 1 50); do [ "$(ipc call bargrid trayslots)" = "$1" ] && return 0; sleep 0.2; done
  return 1
}
if [ "$REAL_OK" = 1 ]; then
  ipc call bargrid setreal true >/dev/null
  run r8n0 8 21 0
  sni_add a; sni_add b
  sni_wait 2 || fail "real: two SNI items reach the bar within 10s" "2" "$(ipc call bargrid trayslots)"
  run r8n2 8 21 0
  sni_add c
  sni_wait 3 || fail "real: a third SNI item reaches the bar within 10s" "3" "$(ipc call bargrid trayslots)"
  run r8n3 8 21 0
  run r10n3 10 20 0
  run rnogrid 0 0 0
  kill "$SNI_a"; SNI_PIDS="${SNI_PIDS/ $SNI_a/}"
  sni_wait 2 || fail "real: an SNI item that exits leaves the bar within 10s" "2" "$(ipc call bargrid trayslots)"
  run r8n2b 8 21 0
fi
grep -a 'CASE ' "$TMP/qs.out" | sed 's/^.*CASE /CASE /' >> "$CASES"
ipc call bargrid bye >/dev/null 2>&1

# ---------------------------------------------------------------- asserts ---
# jq helpers: m($c) = value is a whole multiple of the cell (1/1000 px slack).
JQM='def m($c): ((. * 1000 | round) % ($c * 1000)) == 0;'
jqb() { case_of "$1" | jq -r "$JQM $2" 2>&1; }   # <case> <filter> -> printed
chk() { # <label> <case> <jq filter that yields true/false>
  a2 "$1" "true" "$(jqb "$2" "$3")"
}

for arm in "g8:8:21" "g10:10:20" ; do
  IFS=: read -r n W H <<<"$arm"
  K=$(( (H + W - 1) / W )); SLOT=$(( K * W ))
  SIDE=$(( (SLOT < H ? SLOT : H) - 2 ))
  scenario "kwi3 grid ${W}x${H} (dotfiles-rlnv): right side whole cells, icon ${SIDE}"
  [ -n "$(case_of "$n")" ] || fail "$n dump present" "a dump" "none"
  chk "$n: every visible rightSide child x and width is a whole cell" "$n" \
      ".cell as \$c | [.rsKids[] | (.x|m(\$c)) and (.w|m(\$c))] | all"
  chk "$n: every visible clockDate child x and width is a whole cell" "$n" \
      ".cell as \$c | [.cdKids[] | (.x|m(\$c)) and (.w|m(\$c))] | all"
  # dotfiles-hr1g: EVERY separator (whitespace-only Text: stats, VOL/KBL, bat,
  # the pre-tray one, clock/date) is exactly ONE cell, as is the tray separator.
  chk "$n: every whitespace separator (rightSide+clockDate) is exactly one cell, and there are >= 6" "$n" \
      ".cell as \$c | [(.rsKids + .cdKids)[] | select(.n | test(\"^ +\$\")) | .w] as \$s | (\$s|length) >= 6 and (\$s | all(. == \$c))"
  chk "$n: tray separator is exactly one cell" "$n" ".cell as \$c | .traySepW == \$c"
  chk "$n: rightSide x/width whole cells" "$n" ".cell as \$c | (.rs.x|m(\$c)) and (.rs.w|m(\$c))"
  chk "$n: clockDate x/width whole cells" "$n" ".cell as \$c | (.cd.x|m(\$c)) and (.cd.w|m(\$c))"
  chk "$n: rightSide is flush against clockDate (no drift between blocks)" "$n" \
      ".rs.x + .rs.w == .cd.x"
  a2 "$n: clockDate right margin is exactly one cell" "$W" \
      "$(case_of "$n" | jq -r '.parentW - (.cd.x + .cd.w)')"
  chk "$n: rightSide had content (stats, vol, kbd, tray, bell all laid out)" "$n" \
      "(.rsKids|length) > 10 and .kbd != null and (.tray|length) == 3"
  chk "$n: VOL: label and value are whole cells and the pair is their sum" "$n" \
      ".cell as \$c | (.vol.l.x|m(\$c)) and (.vol.l.w|m(\$c)) and (.vol.v.x|m(\$c)) and (.vol.v.w|m(\$c)) and .vol.g.w == (.vol.l.w + .vol.v.w)"
  chk "$n: KBL: label and value are whole cells and the pair is their sum" "$n" \
      ".cell as \$c | (.kbd.l.x|m(\$c)) and (.kbd.l.w|m(\$c)) and (.kbd.v.x|m(\$c)) and (.kbd.v.w|m(\$c)) and .kbd.g.w == (.kbd.l.w + .kbd.v.w)"
  chk "$n: tray block x/width whole cells, width = ceil(3*H/W)*W" "$n" \
      ".cell as \$c | (.trayBlock.x|m(\$c)) and (.trayBlock.w|m(\$c)) and .trayBlock.w == ((3 * ${H} / \$c | ceil) * \$c)"
  a2 "$n: tray icons are ${SIDE}x${SIDE}, sourceSize ${SIDE} (titlebar-icon size)" \
      "$SIDE $SIDE $SIDE $SIDE" \
      "$(case_of "$n" | jq -r '[.tray[] | "\(.iw) \(.ih) \(.sw) \(.sh)"] | unique | join("|")')"
  a2 "$n: adjacent tray icons sit at pitch H=${H}" "${H} ${H}" \
      "$(case_of "$n" | jq -r '[.tray[].x] as $x | "\($x[1]-$x[0]) \($x[2]-$x[1])"')"
  chk "$n: tray icons are centred in their pitch (1px margin each side)" "$n" \
      "[.tray[] | .ix == 1] | all"
  chk "$n: the bell is its own segment: icon ${SIDE}, segment = ceil((H + count)/W)*W" "$n" \
      ".cell as \$c | (.bell.g.x|m(\$c)) and (.bell.g.w|m(\$c)) and .bell.g.w == (((${H} + .bell.ci) / \$c | ceil) * \$c) and .bell.iw == ${SIDE} and .bell.ih == ${SIDE} and .bell.sw == ${SIDE} and .bell.ix == 1 and .bell.cx == ${H}"
done

for arm in "g8:8:21" "g10:10:20"; do
  IFS=: read -r n W H <<<"$arm"
  SIDE=$(( H - 2 ))
  scenario "tray block over ${W}x${H}, n = 0..4: block = ceil(n*H/W)*W, one rounding for the whole tray"
  for k in 0 1 2 3 4; do
    EXPW=$(( (k * H + W - 1) / W * W ))
    if [ "$k" -eq 0 ]; then
      a2 "${n}n$k: no tray icons and the block takes no width" "0 0" \
          "$(case_of "${n}n$k" | jq -r '"\(.tray|length) \(.trayBlock.w)"')"
      continue
    fi
    a2 "${n}n$k: block width == ceil($k*$H/$W)*$W = $EXPW" "$EXPW" \
        "$(case_of "${n}n$k" | jq -r '.trayBlock.w')"
    chk "${n}n$k: block x is a whole cell" "${n}n$k" ".cell as \$c | (.trayBlock.x|m(\$c))"
    a2 "${n}n$k: $k icons, each ${SIDE}x${SIDE}" "$k|$SIDE $SIDE $SIDE $SIDE" \
        "$(case_of "${n}n$k" | jq -r '"\(.tray|length)|" + ([.tray[] | "\(.iw) \(.ih) \(.sw) \(.sh)"] | unique | join(";"))')"
    a2 "${n}n$k: icons packed at pitch $H, spare split floor-left to the block's two ends" \
        "$(( (EXPW - k * H) / 2 )) $H" \
        "$(case_of "${n}n$k" | jq -r '"\(.trayRowX) \(if (.tray|length) > 1 then .tray[1].x - .tray[0].x else '"$H"' end)"')"
  done
done

scenario "the tray fake is production-shaped (dotfiles-rlnv rejection #1)"
a2 "the fake tray model has NO .length (like SystemTray.items' ObjectModel)" "false" \
    "$(case_of g8 | jq -r '.modelHasLength')"
for c in g8 g10 g8n0 g8n1 g8n2 g8n3 g8n4 g10n0 g10n4 nogrid; do
  a2 "$c: trayCount == laid-out slots and trayRow.x is finite" "true" \
      "$(case_of "$c" | jq -r '.trayCount == (.tray|length) and .trayRowXFinite')"
done
a2 "tray separator: shown iff the tray has icons (n = 0..4)" "false true true true true" \
    "$(for k in 0 1 2 3 4; do case_of "g8n$k" | jq -r '.traySepVisible'; done | tr '\n' ' ' | sed 's/ $//')"
a2 "tray separator on the 8x21 grid is ONE cell (dotfiles-hr1g)" "8" "$(case_of g8n2 | jq -r '.traySepW')"

scenario "the REAL SystemTray.items on a private bus (StatusNotifierItems over D-Bus)"
if [ "$REAL_OK" = 1 ]; then
  a2 "real: SystemTray.items has no .length (the production shape this guards)" "false" \
      "$(case_of r8n0 | jq -r '.modelHasLength')"
  a2 "real n=0: trayCount 0, block 0, trayRow.x finite, separator hidden" "0 0 true false" \
      "$(case_of r8n0 | jq -r '"\(.trayCount) \(.trayBlock.w) \(.trayRowXFinite) \(.traySepVisible)"')"
  for rc in r8n2:8:21:2 r8n3:8:21:3 r10n3:10:20:3 r8n2b:8:21:2; do
    IFS=: read -r c W H k <<<"$rc"; EXPW=$(( (k * H + W - 1) / W * W )); RX=$(( (EXPW - k * H) / 2 ))
    a2 "$c: trayCount $k, $k slots, block ceil($k*$H/$W)*$W = $EXPW, row x $RX, separator shown" \
        "$k $k $EXPW $RX true" \
        "$(case_of "$c" | jq -r '"\(.trayCount) \(.tray|length) \(.trayBlock.w) \(.trayRowX) \(.traySepVisible)"')"
    a2 "$c: real icons $(( H - 2 ))x$(( H - 2 )) at pitch $H" "$(( H - 2 )) $(( H - 2 ))|$H" \
        "$(case_of "$c" | jq -r '([.tray[] | "\(.iw) \(.ih)"] | unique | join(";")) + "|" + ((.tray[1].x - .tray[0].x)|tostring)')"
    chk "$c: every rightSide child x/width is a whole cell with real tray items" "$c" \
        ".cell as \$c | [.rsKids[] | (.x|m(\$c)) and (.w|m(\$c))] | all"
  done
  a2 "real nogrid: trayCount 3, three 18 px slots, separator shown" "3 18 18 18 true" \
      "$(case_of rnogrid | jq -r '"\(.trayCount) \([.tray[].w]|map(tostring)|join(" ")) \(.traySepVisible)"')"
fi

scenario "second visit to 8x21 matches the first (not order dependent)"
a2 "g8b == g8" "$(case_of g8 | jq -cS 'del(.cdKids[].n)')" "$(case_of g8b | jq -cS 'del(.cdKids[].n)')"

scenario "no grid (dotfiles-rlnv): today's look, unchanged"
a2 "nogrid: tray slot 18, icon 14x14, sourceSize 14" "18 18 18|14 14 14 14" \
    "$(case_of nogrid | jq -r '([.tray[].w]|map(tostring)|join(" ")) + "|" + ([.tray[]|"\(.iw) \(.ih) \(.sw) \(.sh)"]|unique|join(";"))')"
a2 "nogrid: bell slot = 14 + count + 4, icon 14x14" "18 14 14 14" \
    "$(case_of nogrid | jq -r '.bell | "\(.g.w - .ci) \(.iw) \(.ih) \(.sw)"')"
a2 "nogrid: clockDate margin 8" "8" "$(case_of nogrid | jq -r '.parentW - (.cd.x + .cd.w)')"
a2 "nogrid: every Text child is exactly its implicitWidth" "true" \
    "$(case_of nogrid | jq -r '[(.rsKids + .cdKids)[] | select(.iw != null) | .w == .iw] | all')"
a2 "nogrid: every separator is exactly ONE space character (dotfiles-hr1g), >= 6 of them" "true" \
    "$(case_of nogrid | jq -r '[(.rsKids + .cdKids)[] | select(.n | test("^ +$")) | .n] as $s | ($s|length) >= 6 and ($s | all(. == " ")) and .traySepText == " "')"
a2 "nogrid: VOL/KBL pair widths are label+value implicit sums" "true" \
    "$(case_of nogrid | jq -r '.vol.g.w == (.vol.l.w + .vol.v.w) and .kbd.g.w == (.kbd.l.w + .kbd.v.w)')"
[ -n "${GEOM_OUT:-}" ] && case_of nogrid | jq -cS 'del(.cdKids[].n)' > "$GEOM_OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ -n "$SKIPS" ] && printf 'SKIP: (UNVERIFIED, not counted as passes)%s\n' "$SKIPS"
[ "$FAIL" -eq 0 ]
