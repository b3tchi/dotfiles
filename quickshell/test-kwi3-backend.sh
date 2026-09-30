#!/usr/bin/env bash
# test-kwi3-backend.sh — headless suite for Kwi3Client + Kwi3Grid (sp004 Task
# 12, kwi3-234.12; ft008/ft010). Sibling of test-mode-bar.sh; same discipline:
# QT_QPA_PLATFORM=offscreen (no Xephyr/Xvfb needed at all — these two
# singletons are pure logic, nothing renders), a sandboxed $HOME and XDG_*
# dirs under /tmp (a SHORT path — quickshell's own IPC socket is AF_UNIX and
# the scratchpad path this repo's agents otherwise prefer is long enough to
# blow the 108-byte sun_path limit; test-mode-bar.sh hits the same constraint
# and uses /tmp for the same reason), named scenarios, printed `KWI3TEST
# <name> <payload>` lines this script asserts against.
#
# THE INSTRUMENT IS THE REAL kwi3 CORE, not a hand-rolled stub: every
# criterion here runs Kwi3Client against `i3kwin/test/rpc-server.js` (kwi3
# repo, sp004 Task 12's own node rig — the twin of ipc-server.js, but for
# core/rpc.js). A client that shares a bug with a hand-rolled echo server
# would pass a test written against that server; it will not pass this one.
# poc003's own latency measurement is NOT re-asserted here — it is not a
# correctness property, and this suite has no timing budget.
#
# ONE edge case genuinely cannot be produced by rpc-server.js: "two calls in
# flight answered out of order". rpc.js's dispatch is synchronous per
# connection (one Logic call per line, in arrival order), so a real core
# server never actually reorders replies — proving the CLIENT dispatches by
# id rather than by arrival order needs a server that deliberately answers
# out of order. That one scenario (PHASE 3) runs against a tiny fixture
# server this script writes to $TMP and discards. The framing edge cases
# (PHASE 4: one reply split across two reads, two replies in one read) need
# a second fixture for the same reason - node writes each reply whole and the
# kernel, not the test, would decide the chunking. PHASE 5 (grid.changed) is
# real core again, through rpc-server.js's own start(). Every other scenario
# here runs rpc-server.js as is.
#
# PHASE 7 (kwi3-234.18) puts a counting stub i3-msg on the Bar's PATH and
# proves the Bar spawns NONE under kwi3 - neither before the socket answers
# nor after - with a no-$KWI3SOCK control that proves the stub is reachable.
#
# Safety (AGENTS.md kwi3-icz twin): this script starts rpc-server.js only
# against socket paths it creates itself under $TMP, kills only PIDs it
# started (never `pkill -f`), and every quickshell invocation explicitly
# unsets $I3SOCK/$SWAYSOCK/$WAYLAND_DISPLAY/$DISPLAY so nothing here can ever
# reach Jan's live session — $KWI3SOCK is always either unset (PHASE 1) or
# pointed at a throwaway socket this script itself bound (PHASES 2-3).
#
# usage: quickshell/test-kwi3-backend.sh
# env:   QUICKSHELL=          (default: from PATH)
#        KWI3_REPO=           kwi3 checkout providing i3kwin/test/rpc-server.js
#                             (default: ~/.local/src/kwi3, matching kwi3/
#                             dot.yaml's own clone convention/override)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/config/Common"

QUICKSHELL="${QUICKSHELL:-quickshell}"
KWI3_REPO="${KWI3_REPO:-$HOME/.local/src/kwi3}"
RPC_SERVER="$KWI3_REPO/i3kwin/test/rpc-server.js"
# PHASE 6 only (the Bar, sp004 Task 13): a real PanelWindow needs a real
# layer-shell/X11 backend — "No PanelWindow backend loaded" under
# QT_QPA_PLATFORM=offscreen, measured while writing that phase — so it is the
# one phase in this file that runs under Xvfb, same as test-mode-bar.sh.
XVFB="${XVFB:-Xvfb}"
BAR_DPY="${BAR_DPY:-:97}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
scenario() { printf '\n[%s]\n' "$1"; }

for tool in "$QUICKSHELL" node "$XVFB"; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (QUICKSHELL=/XVFB= to override)" >&2; exit 1; }
done
[ -d "$COMMON_DIR" ] || { echo "FATAL: $COMMON_DIR not a directory" >&2; exit 1; }
for f in Kwi3Client.qml Kwi3Grid.qml qmldir; do
  [ -r "$COMMON_DIR/$f" ] || { echo "FATAL: $COMMON_DIR/$f missing" >&2; exit 1; }
done
BAR_QML="$SCRIPT_DIR/config/Bar.qml"
[ -r "$BAR_QML" ] || { echo "FATAL: $BAR_QML missing" >&2; exit 1; }
[ -r "$RPC_SERVER" ] || {
  echo "FATAL: $RPC_SERVER not found." >&2
  echo "       Set KWI3_REPO=/path/to/kwi3 to a checkout with i3kwin/test/rpc-server.js" >&2
  echo "       (sp004 Task 12 / kwi3-234.12 — not yet on kwi3's main at the time this" >&2
  echo "       script was written; point KWI3_REPO at the dev worktree until it lands)." >&2
  exit 1
}

TMP="/tmp/qs-kwi3-backend-test.$$"
PIDS=()   # every background pid THIS script started; cleanup kills exactly these

cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  sleep 0.2
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/home"

# --- one shared harness QML, reused by every phase below --------------------
# It never hardcodes which socket it is pointed at — that is entirely the
# $KWI3SOCK each phase's quickshell process is launched with. Every "poll"
# style check (available/grid-active) takes a caller-chosen `tag` so a
# repeated poll's KWI3TEST lines stay individually greppable rather than
# colliding with an earlier poll's own line of the same shape.
write_harness() { # <cfgdir>
  local cfg="$1"
  mkdir -p "$cfg"
  ln -sf "$COMMON_DIR" "$cfg/Common"
  cat > "$cfg/shell.qml" <<'QMLEOF'
import Quickshell
import Quickshell.Io
import QtQuick
import "./Common"

ShellRoot {
    id: host
    function emit(name, payload) { console.log("KWI3TEST " + name + " " + payload) }
    function j(v) { return JSON.stringify(v === undefined ? null : v) }

    property var _events: ({})   // event name -> [params, ...] received so far

    Component.onCompleted: {
        Kwi3Client.on("workspace.focused", function (p) {
            if (!host._events["workspace.focused"]) { host._events["workspace.focused"] = [] }
            host._events["workspace.focused"].push(p)
        })
    }

    IpcHandler {
        target: "kwi3test"

        function available(tag: string): void {
            host.emit("available", tag + " " + (Kwi3Client.available ? "1" : "0"))
        }
        function gridActive(tag: string): void {
            host.emit("grid-active", tag + " " + (Kwi3Grid.active ? "1" : "0"))
        }
        function gridModule(tag: string): void {
            host.emit("grid-module", tag + " " + Kwi3Grid.moduleW + "x" + Kwi3Grid.moduleH)
        }
        function pendingCount(tag: string): void {
            host.emit("pending-count", tag + " " + Object.keys(Kwi3Client._pending).length)
        }
        function wsFocusedCount(tag: string): void {
            var arr = host._events["workspace.focused"] || []
            host.emit("ws-focused-count", tag + " " + arr.length)
        }

        function call(tag: string, method: string, paramsJson: string): void {
            var params = paramsJson === "" ? undefined : JSON.parse(paramsJson)
            Kwi3Client.call(method, params, function (err, res) {
                host.emit("call-done", tag + " " + host.j({ err: err, res: res }))
            })
        }

        // PHASE 3 only: two calls fired back to back against a fixture
        // server that answers "test.slow" LATE and "test.fast" IMMEDIATELY —
        // proving dispatch is by id, not by request order, needs replies to
        // arrive in the opposite order from the requests.
        function raceSlowFast(tag: string): void {
            Kwi3Client.call("test.slow", {}, function (err, res) {
                host.emit("race-result", tag + " slow " + host.j({ err: err, res: res }))
            })
            Kwi3Client.call("test.fast", {}, function (err, res) {
                host.emit("race-result", tag + " fast " + host.j({ err: err, res: res }))
            })
        }

        // PHASE 4 only: two calls fired back to back against a fixture that
        // holds the first reply until the second request arrives, then
        // writes BOTH replies in ONE socket write - two lines in one chunk,
        // each of which must still reach its own callback, exactly once.
        function callPair(tag: string): void {
            Kwi3Client.call("test.pairA", {}, function (err, res) {
                host.emit("pair-result", tag + " A " + host.j({ err: err, res: res }))
            })
            Kwi3Client.call("test.pairB", {}, function (err, res) {
                host.emit("pair-result", tag + " B " + host.j({ err: err, res: res }))
            })
        }

        function bulk(tag: string, n: int): void {
            var remaining = n
            var errors = 0
            for (var i = 0; i < n; i++) {
                Kwi3Client.call("workspace.list", undefined, function (err) {
                    remaining--
                    if (err) { errors++ }
                    if (remaining === 0) {
                        host.emit("bulk-done", tag + " " + errors + " " +
                            Object.keys(Kwi3Client._pending).length)
                    }
                })
            }
        }
    }
}
QMLEOF
}

# --- process/host management --------------------------------------------
# Every quickshell (and rpc-server.js) invocation below goes through these so
# the safety rules in the file header are enforced in exactly one place:
# nothing here ever inherits $I3SOCK/$SWAYSOCK/$WAYLAND_DISPLAY/$DISPLAY, and
# $KWI3SOCK is always either unset or a path this script created under $TMP.

start_rpc_server() { # <sock-path> <logfile>  ->  prints pid on stdout
    node "$RPC_SERVER" "$1" >"$2" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    echo "$pid"
}

wait_for_socket() { # <sock-path> <timeout-s>
    local n=$(( ${2:-10} * 10 )) i
    for i in $(seq 1 "$n"); do
        [ -S "$1" ] && return 0
        sleep 0.1
    done
    return 1
}

# start_host <kwi3sock-or-empty> <name>  ->  sets HOST_PID/HOST_CFG/HOST_RUN/
# HOST_CACHE/HOST_LOG as globals for the ipc()/poll_* helpers below.
start_host() {
    local sock="$1" name="$2"
    HOST_CFG="$TMP/cfg-$name"
    HOST_RUN="$TMP/run-$name"
    HOST_CACHE="$TMP/cache-$name"
    HOST_LOG="$TMP/qs-$name.log"
    mkdir -p "$HOST_RUN" "$HOST_CACHE"
    write_harness "$HOST_CFG"
    env -u I3SOCK -u SWAYSOCK -u WAYLAND_DISPLAY -u DISPLAY \
        HOME="$TMP/home" KWI3SOCK="$sock" QT_QPA_PLATFORM=offscreen \
        XDG_CONFIG_HOME="$HOST_CFG" XDG_RUNTIME_DIR="$HOST_RUN" \
        XDG_CACHE_HOME="$HOST_CACHE" \
        "$QUICKSHELL" -p "$HOST_CFG" >"$HOST_LOG" 2>&1 &
    HOST_PID=$!
    PIDS+=("$HOST_PID")
}

ipc() {
    env XDG_CONFIG_HOME="$HOST_CFG" XDG_RUNTIME_DIR="$HOST_RUN" \
        XDG_CACHE_HOME="$HOST_CACHE" \
        "$QUICKSHELL" ipc --pid "$HOST_PID" "$@" >/dev/null 2>&1
}

wait_target_up() { # <timeout-s>
    local n=$(( ${1:-15} * 5 )) i cnt
    for i in $(seq 1 "$n"); do
        cnt="$(env XDG_CONFIG_HOME="$HOST_CFG" XDG_RUNTIME_DIR="$HOST_RUN" \
                   XDG_CACHE_HOME="$HOST_CACHE" \
                   "$QUICKSHELL" ipc --pid "$HOST_PID" show 2>/dev/null \
               | grep -c 'kwi3test')"
        [ "${cnt:-0}" -gt 0 ] && return 0
        sleep 0.2
    done
    return 1
}

# last_val <field-name> <tag>  ->  the LAST token of the most recent matching
# KWI3TEST line, or "" if none yet.
last_val() {
    grep -a "KWI3TEST $1 $2 " "$HOST_LOG" | tail -1 | awk '{print $NF}'
}
last_payload() { # <field-name> <tag>  ->  everything after "<field> <tag> "
    grep -a "KWI3TEST $1 $2 " "$HOST_LOG" | tail -1 | sed "s/^.*KWI3TEST $1 $2 //"
}

# poll_available <tag-prefix> <expect 0|1> <timeout-s>  ->  0/1 exit status.
# Actively re-queries (not a fixed sleep-and-hope): each attempt is its own
# freshly tagged call, so the log stays unambiguous under repeated polling.
poll_available() {
    local prefix="$1" expect="$2" n=$(( ${3:-10} * 5 )) i tag got
    for i in $(seq 1 "$n"); do
        tag="${prefix}_$i"
        ipc call kwi3test available "$tag"
        sleep 0.15
        got="$(last_val available "$tag")"
        [ "$got" = "$expect" ] && return 0
    done
    return 1
}
poll_grid_active() {
    local prefix="$1" expect="$2" n=$(( ${3:-10} * 5 )) i tag got
    for i in $(seq 1 "$n"); do
        tag="${prefix}_$i"
        ipc call kwi3test gridActive "$tag"
        sleep 0.15
        got="$(last_val grid-active "$tag")"
        [ "$got" = "$expect" ] && return 0
    done
    return 1
}
wait_for_call_done() { # <tag> <timeout-s>
    local tag="$1" n=$(( ${2:-10} * 10 )) i
    for i in $(seq 1 "$n"); do
        grep -aq "KWI3TEST call-done $tag " "$HOST_LOG" && return 0
        sleep 0.1
    done
    return 1
}
wait_for_bulk_done() {
    local tag="$1" n=$(( ${2:-15} * 10 )) i
    for i in $(seq 1 "$n"); do
        grep -aq "KWI3TEST bulk-done $tag " "$HOST_LOG" && return 0
        sleep 0.1
    done
    return 1
}
wait_for_race_results() {
    local tag="$1" n=$(( ${2:-10} * 10 )) i
    for i in $(seq 1 "$n"); do
        [ "$(grep -ac "KWI3TEST race-result $tag " "$HOST_LOG")" -ge 2 ] && return 0
        sleep 0.1
    done
    return 1
}

# PHASE 6 only: is display <1> up? Both socket namespaces (dotfiles-4ai2),
# same check test-mode-bar.sh uses — a WSLg /tmp/.X11-unix bind mount only
# ever gets the abstract socket, never the file.
dpy_up() { # <display>
    [ -e "/tmp/.X11-unix/X${1#:}" ] && return 0
    grep -q "@/tmp/\.X11-unix/X${1#:}\$" /proc/net/unix 2>/dev/null
}

# ============================================================================
# PHASE 1 — no $KWI3SOCK at all: the real-i3/sway case (success criterion 3).
# ============================================================================

scenario "no \$KWI3SOCK: available/active stay false, no reconnect loop (AC3)"
start_host "" "nosock"
if ! wait_target_up 15; then
    fail "quickshell (no socket) exposed the kwi3test IPC target" "target up" "not found"
    tail -30 "$HOST_LOG" >&2
else
    poll_available "boot" "0" 3
    a="$(last_val available boot_1)"
    [ -z "$a" ] && a="0"
    # available must read false at every sample taken (never flaps to "1"):
    # every "available boot_*" line collected over the 3s window must read 0.
    flapped="$(grep -a 'KWI3TEST available boot_' "$HOST_LOG" | awk '{print $NF}' | grep -c '^1$')"
    [ "${flapped:-0}" = "0" ] && pass "available never reads true with no socket" \
        || fail "available never reads true with no socket" "0 occurrences of 1" "$flapped"

    ipc call kwi3test gridActive "boot"
    sleep 0.3
    got="$(last_val grid-active boot)"
    [ "$got" = "0" ] && pass "Kwi3Grid.active is false with no socket" \
        || fail "Kwi3Grid.active is false with no socket" "0" "$got"

    # no error spam: nothing in this process's own log should mention our
    # (nonexistent) socket path failing to connect over and over.
    errs="$(grep -aic 'socket' "$HOST_LOG" | tr -d ' ')"
    [ "${errs:-0}" -le 1 ] && pass "no socket-related log spam with \$KWI3SOCK unset" \
        || fail "no socket-related log spam with \$KWI3SOCK unset" "<=1 mention" "$errs"
fi
kill "$HOST_PID" 2>/dev/null

# ============================================================================
# PHASE 2 — against the REAL core (i3kwin/test/rpc-server.js). Success
# criteria 1 and 2, plus the error-object and 1000-call edge cases (both
# reachable with the real server; only true reordering cannot be).
# ============================================================================

SOCK_A="$TMP/kwi3-a.sock"
RPC_LOG_A="$TMP/rpc-a.log"
RPC_PID_A="$(start_rpc_server "$SOCK_A" "$RPC_LOG_A")"

scenario "boot: rpc-server.js up, Kwi3Client connects (AC1)"
if ! wait_for_socket "$SOCK_A" 20; then
    fail "rpc-server.js bound $SOCK_A" "socket present" "missing"
    cat "$RPC_LOG_A" >&2
else
    pass "rpc-server.js bound its socket"
fi

start_host "$SOCK_A" "real"
if ! wait_target_up 15; then
    fail "quickshell (real server) exposed the kwi3test IPC target" "target up" "not found"
    tail -30 "$HOST_LOG" >&2
else
    pass "quickshell exposed the kwi3test IPC target"

    if poll_available "up" "1" 10; then
        pass "Kwi3Client.available becomes true against a real server"
    else
        fail "Kwi3Client.available becomes true against a real server" "1" "$(last_val available up_1)"
    fi

    scenario "workspace.list completes (AC1)"
    ipc call kwi3test call "wl1" "workspace.list" ""
    if wait_for_call_done "wl1" 10; then
        payload="$(last_payload call-done wl1)"
        case "$payload" in
            *'"err":null'*'"res":['*) pass "workspace.list returns a result array with no error" ;;
            *) fail "workspace.list returns a result array with no error" '"err":null, "res":[...]' "$payload" ;;
        esac
    else
        fail "workspace.list completes" "a call-done line" "(timed out)"
    fi

    scenario "workspace.focus -> a workspace.focused notification is received (AC1)"
    ipc call kwi3test wsFocusedCount "before"
    sleep 0.2
    before="$(last_val ws-focused-count before)"
    ipc call kwi3test call "focus1" "workspace.focus" '{"num":2}'
    wait_for_call_done "focus1" 10 >/dev/null
    ipc call kwi3test wsFocusedCount "after"
    sleep 0.2
    after="$(last_val ws-focused-count after)"
    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
        pass "workspace.focus is followed by a workspace.focused notification"
    else
        fail "workspace.focus is followed by a workspace.focused notification" \
            "count increased" "before=$before after=$after"
    fi

    scenario "Kwi3Grid.active becomes true, moduleW==8 moduleH==21 for the default grid (AC1)"
    if poll_grid_active "grid" "1" 10; then
        pass "Kwi3Grid.active becomes true"
        ipc call kwi3test gridModule "dims"
        sleep 0.2
        dims="$(last_val grid-module dims)"
        [ "$dims" = "8x21" ] && pass "Kwi3Grid module is 8x21 (defaults.js MODULE_W/MODULE_H)" \
            || fail "Kwi3Grid module is 8x21" "8x21" "$dims"
    else
        fail "Kwi3Grid.active becomes true" "1" "$(last_val grid-active grid_1)"
    fi

    scenario "a server error object reaches the call() callback (edge case)"
    ipc call kwi3test call "err1" "no.such.method" ""
    if wait_for_call_done "err1" 10; then
        payload="$(last_payload call-done err1)"
        case "$payload" in
            *'"code":-32601'*) pass "an unknown method's error object reaches the callback" ;;
            *) fail "an unknown method's error object reaches the callback" '"code":-32601' "$payload" ;;
        esac
    else
        fail "a server error reaches the callback" "a call-done line" "(timed out)"
    fi

    scenario "1000 calls: every callback fires, no leak of pending callbacks (edge case)"
    ipc call kwi3test bulk "bulk1" "1000"
    if wait_for_bulk_done "bulk1" 30; then
        payload="$(last_payload bulk-done bulk1)"
        errors="$(echo "$payload" | awk '{print $1}')"
        pendingLeft="$(echo "$payload" | awk '{print $2}')"
        [ "$errors" = "0" ] && pass "1000 calls: zero errors" \
            || fail "1000 calls: zero errors" "0" "$errors"
        [ "$pendingLeft" = "0" ] && pass "1000 calls: no leaked pending callbacks" \
            || fail "1000 calls: no leaked pending callbacks" "0" "$pendingLeft"
    else
        fail "1000 calls all complete" "a bulk-done line" "(timed out)"
    fi

    scenario "kill and restart the server: reconnect + resubscribe within the backoff (AC2)"
    kill "$RPC_PID_A" 2>/dev/null
    for i in $(seq 1 30); do kill -0 "$RPC_PID_A" 2>/dev/null || break; sleep 0.1; done

    if poll_available "down" "0" 10; then
        pass "available goes false once the server is killed"
    else
        fail "available goes false once the server is killed" "0" "$(last_val available down_1)"
    fi

    RPC_LOG_B="$TMP/rpc-b.log"
    RPC_PID_B="$(start_rpc_server "$SOCK_A" "$RPC_LOG_B")"   # same socket path
    if ! wait_for_socket "$SOCK_A" 20; then
        fail "restarted rpc-server.js rebound $SOCK_A" "socket present" "missing"
        cat "$RPC_LOG_B" >&2
    else
        pass "restarted rpc-server.js rebound the same socket path"
    fi

    if poll_available "reup" "1" 25; then
        pass "available goes true again after the server restarts (within the backoff)"

        ipc call kwi3test wsFocusedCount "prerestart"
        sleep 0.2
        pre="$(last_val ws-focused-count prerestart)"
        # num:2 deliberately — the restarted server is a FRESH world starting
        # on workspace 1, so num:1 would be a no-op (already focused there)
        # and emit no event at all, proving nothing about resubscription.
        ipc call kwi3test call "focus2" "workspace.focus" '{"num":2}'
        wait_for_call_done "focus2" 10 >/dev/null
        ipc call kwi3test wsFocusedCount "postrestart"
        sleep 0.2
        post="$(last_val ws-focused-count postrestart)"
        if [ -n "$pre" ] && [ -n "$post" ] && [ "$post" -gt "$pre" ]; then
            pass "the client resubscribed automatically after reconnecting"
        else
            fail "the client resubscribed automatically after reconnecting" \
                "count increased" "pre=$pre post=$post"
        fi
    else
        fail "available goes true again after the server restarts" "1" "$(last_val available reup_1)"
    fi
fi
kill "$HOST_PID" 2>/dev/null
kill "$RPC_PID_B" 2>/dev/null

# ============================================================================
# PHASE 3 — a fixture server that answers deliberately out of order, so the
# ONE edge case a synchronous real core cannot produce is still exercised:
# two calls in flight, answered in the opposite order from the requests.
# ============================================================================

scenario "two calls in flight answered out of order: dispatch is by id (edge case)"
FIXTURE="$TMP/fake-reorder-server.js"
cat > "$FIXTURE" <<'JSEOF'
// Throwaway fixture, NOT part of the kwi3 repo: answers "test.slow" after a
// delay and "test.fast" immediately, so replies arrive in the OPPOSITE order
// from the requests regardless of what id the client happened to assign each
// one — the one shape core/rpc.js's synchronous, single-threaded dispatch can
// never produce on its own.
'use strict';
const net = require('net');
const fs = require('fs');
const sockPath = process.argv[2];
try { fs.unlinkSync(sockPath); } catch (e) { /* not there */ }
const server = net.createServer((sock) => {
    let buf = '';
    sock.on('data', (chunk) => {
        buf += chunk.toString('utf8');
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            if (!line.trim()) { continue; }
            let req;
            try { req = JSON.parse(line); } catch (e) { continue; }
            if (!req || typeof req !== 'object' || !('id' in req)) { continue; }
            const reply = JSON.stringify({ jsonrpc: '2.0', id: req.id, result: { tag: req.method } }) + '\n';
            if (req.method === 'test.slow') {
                setTimeout(() => { if (!sock.destroyed) { sock.write(reply); } }, 300);
            } else {
                sock.write(reply);
            }
        }
    });
});
server.listen(sockPath, () => { console.log(sockPath); });
JSEOF

SOCK_R="$TMP/kwi3-reorder.sock"
node "$FIXTURE" "$SOCK_R" >"$TMP/reorder.log" 2>&1 &
REORDER_PID=$!
PIDS+=("$REORDER_PID")

if ! wait_for_socket "$SOCK_R" 10; then
    fail "reorder fixture bound $SOCK_R" "socket present" "missing"
    cat "$TMP/reorder.log" >&2
else
    start_host "$SOCK_R" "reorder"
    if ! wait_target_up 15; then
        fail "quickshell (reorder fixture) exposed the kwi3test IPC target" "target up" "not found"
        tail -30 "$HOST_LOG" >&2
    else
        poll_available "rup" "1" 10 >/dev/null
        ipc call kwi3test raceSlowFast "race1"
        if wait_for_race_results "race1" 5; then
            fast_line="$(grep -a "KWI3TEST race-result race1 fast " "$HOST_LOG" | tail -1)"
            slow_line="$(grep -a "KWI3TEST race-result race1 slow " "$HOST_LOG" | tail -1)"
            case "$fast_line" in
                *'"tag":"test.fast"'*) pass "the SECOND request's (fast) reply reaches its OWN callback" ;;
                *) fail "the fast reply reaches its own callback" '"tag":"test.fast"' "$fast_line" ;;
            esac
            case "$slow_line" in
                *'"tag":"test.slow"'*) pass "the FIRST request's (slow) reply reaches its OWN callback, arriving later" ;;
                *) fail "the slow reply reaches its own callback" '"tag":"test.slow"' "$slow_line" ;;
            esac
        else
            fail "both race-result lines appear" "2 lines" "$(grep -ac 'KWI3TEST race-result race1 ' "$HOST_LOG")"
        fi
    fi
    kill "$HOST_PID" 2>/dev/null
fi
kill "$REORDER_PID" 2>/dev/null

# ============================================================================
# PHASE 4 — framing: a reply split across reads, and two replies in one read
# (edge case "a reply split across reads (SplitParser)"). Line assembly is
# delegated to Quickshell's SplitParser rather than written here, and a
# delegated edge case counts only if a test proves it. rpc-server.js cannot
# produce either shape on purpose: node writes each reply whole, so the kernel
# decides how a reply is chunked. This fixture decides deliberately instead:
#   test.split       one reply in TWO writes 200ms apart, cut mid-JSON AND
#                    inside a 4-byte UTF-8 sequence (U+1D11E), so a parser
#                    that decodes each chunk on its own mangles the text even
#                    when it reassembles the line.
#   test.pairA/B     A is held until B arrives, then BOTH replies go out in
#                    ONE write: two lines in one chunk, two callbacks.
# ============================================================================

scenario "a reply split across reads, mid-JSON and mid-UTF-8 (edge case)"
CHUNK_FIXTURE="$TMP/fake-chunk-server.js"
cat > "$CHUNK_FIXTURE" <<'JSEOF'
// Throwaway fixture, NOT part of the kwi3 repo: controls exactly how reply
// bytes are chunked on the socket (see PHASE 4's header in the suite).
'use strict';
const net = require('net');
const fs = require('fs');
const sockPath = process.argv[2];
try { fs.unlinkSync(sockPath); } catch (e) { /* not there */ }
const SPLIT_TEXT = 'split é€ 𝄞 end';   // 2-, 3-, 4-byte UTF-8
const server = net.createServer((sock) => {
    let buf = '';
    let heldA = null;
    const replyOf = (id, result) =>
        JSON.stringify({ jsonrpc: '2.0', id: id, result: result }) + '\n';
    sock.on('data', (chunk) => {
        buf += chunk.toString('utf8');
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            let req;
            try { req = JSON.parse(line); } catch (e) { continue; }
            if (!req || typeof req !== 'object' || !('id' in req)) { continue; }
            if (req.method === 'test.split') {
                const bytes = Buffer.from(replyOf(req.id, { text: SPLIT_TEXT }), 'utf8');
                // Cut two bytes into the 4-byte sequence: mid-JSON (inside a
                // string value) and mid-codepoint at once.
                const cut = bytes.indexOf(Buffer.from('𝄞', 'utf8')) + 2;
                sock.write(bytes.subarray(0, cut));
                console.log('WROTE1 ' + cut + '/' + bytes.length);
                setTimeout(() => {
                    if (sock.destroyed) { return; }
                    sock.write(bytes.subarray(cut));
                    console.log('WROTE2 ' + (bytes.length - cut) + '/' + bytes.length);
                }, 200);
            } else if (req.method === 'test.pairA') {
                heldA = replyOf(req.id, { tag: 'A' });
            } else if (req.method === 'test.pairB') {
                const both = (heldA || '') + replyOf(req.id, { tag: 'B' });
                heldA = null;
                sock.write(both);              // ONE write, two lines
                console.log('WROTEPAIR ' + both.split('\n').length);
            }
        }
    });
});
server.listen(sockPath, () => { console.log(sockPath); });
JSEOF

SOCK_C="$TMP/kwi3-chunk.sock"
node "$CHUNK_FIXTURE" "$SOCK_C" >"$TMP/chunk.log" 2>&1 &
CHUNK_PID=$!
PIDS+=("$CHUNK_PID")
# The exact text the fixture sends, spelled as UTF-8 bytes here rather than
# typed, so this file's own encoding cannot make the comparison pass.
SPLIT_EXPECT="$(printf 'split \xc3\xa9\xe2\x82\xac \xf0\x9d\x84\x9e end')"

if ! wait_for_socket "$SOCK_C" 10; then
    fail "chunk fixture bound $SOCK_C" "socket present" "missing"
    cat "$TMP/chunk.log" >&2
else
    start_host "$SOCK_C" "chunk"
    if ! wait_target_up 15; then
        fail "quickshell (chunk fixture) exposed the kwi3test IPC target" "target up" "not found"
        tail -30 "$HOST_LOG" >&2
    else
        poll_available "cup" "1" 10 >/dev/null
        ipc call kwi3test call "split1" "test.split" '{}'
        if wait_for_call_done "split1" 5; then
            sleep 0.5    # long enough for a duplicate dispatch to show up
            n="$(grep -ac 'KWI3TEST call-done split1 ' "$HOST_LOG")"
            payload="$(last_payload call-done split1)"
            [ "$n" = "1" ] && pass "the split reply's callback fires exactly once" \
                || fail "the split reply's callback fires exactly once" "1" "$n"
            [ "$payload" = "{\"err\":null,\"res\":{\"text\":\"$SPLIT_EXPECT\"}}" ] \
                && pass "the split reply is reassembled byte-exact (mid-JSON, mid-UTF-8)" \
                || fail "the split reply is reassembled byte-exact" \
                        "{\"err\":null,\"res\":{\"text\":\"$SPLIT_EXPECT\"}}" "$payload"
            grep -aq '^WROTE2 ' "$TMP/chunk.log" \
                && pass "the fixture really sent the reply as two separate writes" \
                || fail "the fixture really sent the reply as two separate writes" \
                        "WROTE1 + WROTE2 in its log" "$(cat "$TMP/chunk.log")"
        else
            fail "the split reply reaches its callback" "a call-done line" "(timed out)"
        fi

        scenario "two replies in ONE read: each reaches its own callback, once (edge case)"
        ipc call kwi3test callPair "pair1"
        for i in $(seq 1 50); do
            [ "$(grep -ac 'KWI3TEST pair-result pair1 ' "$HOST_LOG")" -ge 2 ] && break
            sleep 0.1
        done
        sleep 0.5
        a_lines="$(grep -a 'KWI3TEST pair-result pair1 A ' "$HOST_LOG")"
        b_lines="$(grep -a 'KWI3TEST pair-result pair1 B ' "$HOST_LOG")"
        a_n="$(printf '%s' "$a_lines" | grep -c .)"
        b_n="$(printf '%s' "$b_lines" | grep -c .)"
        [ "$a_n" = "1" ] && [ "$b_n" = "1" ] \
            && pass "both callbacks fire, each exactly once" \
            || fail "both callbacks fire, each exactly once" "A=1 B=1" "A=$a_n B=$b_n"
        case "$a_lines" in
            *'{"err":null,"res":{"tag":"A"}}') pass "the first line of the chunk reaches A's callback" ;;
            *) fail "the first line of the chunk reaches A's callback" '{"tag":"A"}' "$a_lines" ;;
        esac
        case "$b_lines" in
            *'{"err":null,"res":{"tag":"B"}}') pass "the second line of the chunk reaches B's callback" ;;
            *) fail "the second line of the chunk reaches B's callback" '{"tag":"B"}' "$b_lines" ;;
        esac
        grep -aq '^WROTEPAIR 3$' "$TMP/chunk.log" \
            && pass "the fixture really sent both replies in one write" \
            || fail "the fixture really sent both replies in one write" \
                    "WROTEPAIR 3" "$(grep -a WROTEPAIR "$TMP/chunk.log")"
    fi
    kill "$HOST_PID" 2>/dev/null
fi
kill "$CHUNK_PID" 2>/dev/null

# ============================================================================
# PHASE 5 — Kwi3Grid re-reads on grid.changed. kwi3-234.19 gave the event a
# real emit site (core/rpc.js rpcGridDiff(), run from ipcNotify()), so this
# is real core again: a small driver loads rpc-server.js's own start() and,
# on SIGUSR1, changes the grid through configure() - the same path
# rpc-codec.js section 20 drives - then runs ipcNotify(), the pump every
# command already ends in. Nothing on the client side polls, so the module
# can only change if the notification arrived and Kwi3Grid called grid.get.
# ============================================================================

scenario "Kwi3Grid re-reads on grid.changed (ft008)"
GRID_DRIVER="$TMP/grid-driver.js"
cat > "$GRID_DRIVER" <<'JSEOF'
'use strict';
const fs = require('fs');
const path = require('path');
const [rpcServer, sockPath] = process.argv.slice(2);
const root = path.join(path.dirname(rpcServer), '..');
const sources = fs.readdirSync(path.join(root, 'core'))
    .filter((f) => f.endsWith('.js'))
    .map((f) => path.join(root, 'core', f))
    .concat([path.join(root, 'adapters/kwin/contents/code/adapter.js')]);
require(rpcServer).start(sockPath, sources, {}).then((rig) => {
    rig.openWindow('rig-term-1');
    process.on('SIGUSR1', () => {
        rig.ctx.configure({ module: '10x24' });
        rig.ctx.ipcNotify();
        console.log('CONFIGURED ' + JSON.stringify(rig.ctx.rpcGridGet().module));
    });
    process.on('SIGTERM', () => rig.stop().then(() => process.exit(0)));
    console.log(sockPath);
}, (err) => { console.error('grid-driver: ' + err); process.exit(1); });
JSEOF

SOCK_G="$TMP/kwi3-grid.sock"
node "$GRID_DRIVER" "$RPC_SERVER" "$SOCK_G" >"$TMP/grid.log" 2>&1 &
GRID_PID=$!
PIDS+=("$GRID_PID")

if ! wait_for_socket "$SOCK_G" 20; then
    fail "grid driver bound $SOCK_G" "socket present" "missing"
    cat "$TMP/grid.log" >&2
else
    start_host "$SOCK_G" "grid"
    if ! wait_target_up 15; then
        fail "quickshell (grid driver) exposed the kwi3test IPC target" "target up" "not found"
        tail -30 "$HOST_LOG" >&2
    elif ! poll_grid_active "gup" "1" 10; then
        fail "Kwi3Grid.active becomes true (grid driver)" "1" "$(last_val grid-active gup_1)"
    else
        ipc call kwi3test gridModule "g0"
        sleep 0.2
        g0="$(last_val grid-module g0)"
        [ "$g0" = "8x21" ] && pass "Kwi3Grid starts on the default 8x21" \
            || fail "Kwi3Grid starts on the default 8x21" "8x21" "$g0"
        # Kwi3Grid's events.subscribe went out on the same socket before its
        # grid.get, and grid.get has been answered, so the core has already
        # registered the subscription by now.
        kill -USR1 "$GRID_PID"
        got=""
        for i in $(seq 1 25); do
            ipc call kwi3test gridModule "g1_$i"
            sleep 0.2
            got="$(last_val grid-module "g1_$i")"
            [ "$got" = "10x24" ] && break
        done
        grep -aq '^CONFIGURED {"w":10,"h":24}$' "$TMP/grid.log" \
            && pass "the core's grid really changed to 10x24" \
            || fail "the core's grid really changed to 10x24" "CONFIGURED line" "$(cat "$TMP/grid.log")"
        [ "$got" = "10x24" ] && pass "Kwi3Grid re-read the grid on grid.changed (8x21 -> 10x24)" \
            || fail "Kwi3Grid re-read the grid on grid.changed" "10x24" "$got"
    fi
    kill "$HOST_PID" 2>/dev/null
fi
kill "$GRID_PID" 2>/dev/null

# ============================================================================
# PHASE 6 (sp004 Task 13, kwi3-234.13; ft008/ft010) — the dotfiles Bar itself,
# on Kwi3Client, sized on the grid. The only phase in this file needing a
# real display: a PanelWindow refuses to instantiate under
# QT_QPA_PLATFORM=offscreen ("No PanelWindow backend loaded", measured while
# writing this phase), so it runs under Xvfb, same discipline as
# test-mode-bar.sh — its own PATH sandbox has no i3-msg/swaymsg at all (unlike
# test-mode-bar.sh's own stub), so the pre-existing i3-msg Processes in Bar.qml
# fail to spawn and can never race root.sortedWorkspaces against the kwi3
# feed under test; their try/catch already only ever assigns on a
# successful parse, which a nonexistent binary's silence can never produce.
#
# AC2's "whole modules" half is checked against the REAL rendered
# "a"/"bb"/"ccc" tabs with GENERAL invariants (whole modules, cumulative x
# from contentLeft, EVERY tab's cell count equal to its own want -
# kwi3-55l.16, not shared out of a total) that hold regardless of this
# box's actual monospace font metrics, so the suite does not depend on
# exactly what "monospace" measures here. (Until kwi3-55l.16 it was also
# pinned through a direct call to an equal-share helper in Bar.qml; that
# helper had no production caller left once tabCellPlan stopped sharing a
# total, and was removed with its pin - the chrome's own tab GROUPS run
# i3kwin/core/solver.js, never Bar.qml.) kwi3-55l.16's own scenario
# (below) is what proves a tab never gets LESS than it asked for, under a
# realistic mix of workspace-name lengths and Jan's own font/module.
# ============================================================================

scenario "PHASE 6 setup: rpc-server.js rig + a real Bar under Xvfb"

"$XVFB" "$BAR_DPY" -screen 0 1024x300x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
PIDS+=("$XVFB_PID")
for i in $(seq 1 50); do dpy_up "$BAR_DPY" && break; sleep 0.1; done
if ! dpy_up "$BAR_DPY"; then
    fail "Xvfb $BAR_DPY started" "display up" "not found"
    cat "$TMP/xvfb.log" >&2
else
    BAR_DRIVER="$TMP/bar-driver.js"
    cat > "$BAR_DRIVER" <<'JSEOF'
'use strict';
const fs = require('fs');
const path = require('path');
const [rpcServer, sockPath, cmdDir, mode] = process.argv.slice(2);
const root = path.join(path.dirname(rpcServer), '..');
const sources = fs.readdirSync(path.join(root, 'core'))
    .filter((f) => f.endsWith('.js'))
    .map((f) => path.join(root, 'core', f))
    .concat([path.join(root, 'adapters/kwin/contents/code/adapter.js')]);
require(rpcServer).start(sockPath, sources, {}).then((rig) => {
    // mode "restart": the SECOND rig of the kwi3-restart scenario. A fresh
    // world with a deliberately DIFFERENT workspace set ("x", "yy"), made
    // before any client connects, so the only way the bar can show it is a
    // re-list after Kwi3Client reconnects.
    if (mode === 'restart') {
        rig.ctx.dispatch('workspace:x');
        rig.openWindow('x-win');
        rig.ctx.dispatch('workspace:yy');
        rig.openWindow('yy-win');
    }
    console.log('BOOT ' + JSON.stringify(rig.ctx.workspacesJson()));
    console.log('BOOTGRID ' + JSON.stringify(rig.ctx.rpcGridGet()));

    // Named commands, one file each under cmdDir (processed then deleted):
    // there are more of these than there are spare signals.
    //   long    - a 200-char workspace (edge case: a name wider than the bar)
    //   grid    - the grid changes under a live bar: module 8x21 -> 10x24
    //             through configure() + ipcNotify(), PHASE 5's own path
    //   project - the dotfiles projects picker's own RPC pair
    //             (kwi3-55l.16, below)
    //   realistic - Jan's OWN font/module (kwi3-55l.16: the live bug -
    //             mixed bare-numbered and project-named workspaces, sized
    //             with his real font, not "monospace")
    setInterval(() => {
        let names = [];
        try { names = fs.readdirSync(cmdDir).sort(); } catch (e) { return; }
        for (const name of names) {
            try { fs.unlinkSync(path.join(cmdDir, name)); } catch (e) { continue; }
            if (name === 'long') {
                rig.ctx.dispatch('workspace:' + 'L'.repeat(200));
                rig.openWindow('long-win');
                console.log('LONG ' + JSON.stringify(rig.ctx.workspacesJson()));
            } else if (name === 'grid') {
                rig.ctx.configure({ module: '10x24' });
                rig.ctx.ipcNotify();
                console.log('GRID ' + JSON.stringify(rig.ctx.rpcGridGet()));
            } else if (name === 'project') {
                // Exactly the two RPC pairs Overlay.qml's kwi3 path
                // (projectsSwitch/_kwi3ProjectsNew) sends, run through the
                // same RPC_METHODS table a real socket call would reach
                // (kwi3-55l.16): a project with a pre-existing BARE
                // workspace ("alpha") goes through workspace.rename
                // (bare -> alpha_1) then workspace.focus (alpha_2) -
                // Shift+Enter's rename chain (AC1c); a brand-new project
                // with no live workspace ("gamma") goes through
                // workspace.focus alone - Enter's (and Shift+Enter's own)
                // zero-workspaces branch.
                rig.ctx.dispatch('workspace:alpha');
                rig.openWindow('alpha-keeper'); // keeper: switching away must not reap it
                const bare = rig.ctx.rpcWorkspaceList().find((w) => w.name === 'alpha');
                rig.ctx.RPC_METHODS['workspace.rename'].run(null, { id: bare.id, name: 'alpha_1' });
                rig.ctx.RPC_METHODS['workspace.focus'].run(null, { name: 'alpha_2' });
                rig.openWindow('alpha2-keeper'); // keeper: switching away must not reap it
                rig.ctx.RPC_METHODS['workspace.focus'].run(null, { name: 'gamma' });
                console.log('PROJECT ' + JSON.stringify(rig.ctx.workspacesJson()));
            } else if (name === 'realistic') {
                // Jan's OWN production settings (~/.dotfiles/kwi3/config.js:
                // font 'Iosevka 16', module [8, 21]) - not the neutral
                // built-in default this rig otherwise boots on, and not the
                // 10x24 the 'grid' command above leaves behind. A mix of a
                // bare-numbered workspace (what $mod+<n> names one) and
                // several project-named ones, matching the exact shape of
                // Jan's real session on 3392: short digits beside
                // multi-character project names.
                rig.ctx.configure({ font: 'Iosevka 16', module: '8x21' });
                rig.ctx.ipcNotify();
                rig.ctx.dispatch('workspace:9');
                rig.openWindow('nine-keeper');
                rig.ctx.dispatch('workspace:asahi');
                rig.openWindow('asahi-keeper');
                rig.ctx.dispatch('workspace:kwi3');
                rig.openWindow('kwi3-keeper');
                rig.ctx.dispatch('workspace:dotfiles');
                rig.openWindow('dotfiles-keeper');
                console.log('REALISTIC ' + JSON.stringify(rig.ctx.workspacesJson()));
                console.log('REALISTICGRID ' + JSON.stringify(rig.ctx.rpcGridGet()));
            }
        }
    }, 50);

    // SIGUSR1: three unevenly-named workspaces, "a" focused last — the fixed
    // input to AC1's list/highlight assertions and AC2's whole-module tabs.
    // A window ("keeper") on each one BEFORE switching away is required: an
    // empty workspace switched away from is destroyed (workspace-lifecycle.js
    // section 1's own "keeper" comment) — without it only the LAST-focused
    // name would ever survive, which is exactly the failure mode measured
    // the first time this ran (only "a" persisted).
    process.on('SIGUSR1', () => {
        rig.ctx.dispatch('workspace:a');
        rig.openWindow('a-win');
        rig.ctx.dispatch('workspace:bb');
        rig.openWindow('bb-win');
        rig.ctx.dispatch('workspace:ccc');
        rig.openWindow('ccc-win');
        rig.ctx.dispatch('workspace:a');
        console.log('THREE ' + JSON.stringify(rig.ctx.workspacesJson()));
    });

    // SIGUSR2: a SECOND "client" — this process, not the bar under test —
    // focuses "bb" directly through Logic. Proves the bar follows a
    // workspace.focus notification it did not itself send (AC1).
    process.on('SIGUSR2', () => {
        rig.ctx.dispatch('workspace:bb');
        console.log('FOCUSEDBB ' + JSON.stringify(rig.ctx.workspacesJson()));
    });

    // Mirrors every workspace.focus call the RPC SOCKET actually received
    // (rig.calls only wraps RPC_METHODS — ctx.dispatch() above never touches
    // it) so the click scenario can count them without a signal of its own.
    let lastLen = 0;
    setInterval(() => {
        if (rig.calls.length === lastLen) { return; }
        lastLen = rig.calls.length;
        const focusCalls = rig.calls.filter((c) => c.method === 'workspace.focus');
        console.log('FOCUSCALLS ' + JSON.stringify(focusCalls));
    }, 50);

    process.on('SIGTERM', () => rig.stop().then(() => process.exit(0)));
    console.log(sockPath);
}, (err) => { console.error('bar-driver: ' + err); process.exit(1); });
JSEOF

    SOCK_BAR="$TMP/kwi3-bar.sock"
    BAR_RIG_LOG="$TMP/bar-rig.log"
    BAR_CMD="$TMP/bar-cmd"
    mkdir -p "$BAR_CMD"
    bar_cmd() { : > "$BAR_CMD/$1"; }
    node "$BAR_DRIVER" "$RPC_SERVER" "$SOCK_BAR" "$BAR_CMD" >"$BAR_RIG_LOG" 2>&1 &
    BAR_RIG_PID=$!
    PIDS+=("$BAR_RIG_PID")

    if ! wait_for_socket "$SOCK_BAR" 20; then
        fail "bar-driver.js bound $SOCK_BAR" "socket present" "missing"
        cat "$BAR_RIG_LOG" >&2
    else
        pass "bar-driver.js bound its socket"

        CFG6="$TMP/cfg6"
        RUN6="$TMP/run6"
        CACHE6="$TMP/cache6"
        PBIN6="$TMP/pbin6"          # sandbox PATH: coreutils only, NO i3-msg
        HOST6_LOG="$TMP/qs-bar.log"
        mkdir -p "$CFG6" "$RUN6" "$CACHE6" "$PBIN6"
        chmod 700 "$RUN6"
        ln -sf "$COMMON_DIR" "$CFG6/Common"
        ln -sf "$BAR_QML" "$CFG6/Bar.qml"
        for t in sh cat sleep tr awk df grep sed cut head; do
            src="$(command -v "$t")" && ln -sf "$src" "$PBIN6/$t"
        done

        cat > "$CFG6/shell.qml" <<'QMLEOF'
import Quickshell
import Quickshell.Io
import QtQuick
import "./Common"

ShellRoot {
    id: host
    function emit(n, p) { console.log("KWI3TEST6 " + n + " " + p) }

    function rootOf(w) { return (w && w.contentItem) ? w.contentItem : w }
    function findAllByName(item, name, out) {
        if (!item) { return }
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (c.objectName === name) { out.push(c) }
            findAllByName(c, name, out)
        }
    }

    IpcHandler {
        target: "bar6"

        function geometry(tag: string): void {
            var r = host.rootOf(bar)
            var tabs = []
            host.findAllByName(r, "wsTab", tabs)
            var out = { count: tabs.length, height: bar.height, exclusiveZone: bar.exclusiveZone,
                        grid: { active: Kwi3Grid.active, rowHeight: Kwi3Grid.rowHeight,
                                reserve: Kwi3Grid.reserve, moduleW: Kwi3Grid.moduleW,
                                contentLeft: Kwi3Grid.contentLeft,
                                fontFamily: Kwi3Grid.fontFamily,
                                fontPixelSize: Kwi3Grid.fontPixelSize },
                        tabs: [] }
            for (var i = 0; i < tabs.length; i++) {
                var p = tabs[i].mapToItem(r, 0, 0)
                // The label as it is actually PAINTED: its own x and painted
                // width in bar coordinates, so a label that runs past its
                // tab is visible as numbers (the long-name edge case).
                var texts = []
                host.findAllByName(tabs[i], "wsTabText", texts)
                var t = texts.length ? texts[0] : null
                var tp = t ? t.mapToItem(r, 0, 0) : null
                // The agent-census badge beside the name (kwi3-55l.16): read
                // alongside the name text so a scenario can prove BOTH are
                // visible at once, not merely that the badge exists while
                // the name it sits beside has collapsed to nothing.
                var badges = []
                host.findAllByName(tabs[i], "wsAgentBadge", badges)
                var bdg = badges.length ? badges[0] : null
                // dotfiles-8luk: the tab's own highlight rectangle (label + one
                // gap each side, overhanging the tab), in bar coordinates, and
                // its colour, so 'focused = label + 1 cell each side' is read
                // off the painted item and not derived from the plan.
                var hls = []
                host.findAllByName(tabs[i], "wsTabHighlight", hls)
                var hl = hls.length ? hls[0] : null
                var hp = hl ? hl.mapToItem(r, 0, 0) : null
                // The label row (name + badge) as painted: the thing whose
                // gap to its neighbour is what Jan reads (dotfiles-8luk).
                var rows = []
                host.findAllByName(tabs[i], "wsLabelRow", rows)
                var lr = rows.length ? rows[0] : null
                var lp = lr ? lr.mapToItem(r, 0, 0) : null
                out.tabs.push({ x: p.x, width: tabs[i].width, clip: tabs[i].clip,
                                rowX: lp ? lp.x : null, rowW: lr ? lr.width : null,
                                hlX: hp ? hp.x : null, hlW: hl ? hl.width : null,
                                hlColor: hl ? String(hl.color) : null,
                                textX: tp ? tp.x : null,
                                textPainted: t ? t.paintedWidth : null,
                                textWidth: t ? t.width : null,
                                truncated: t ? t.truncated : null,
                                // The string actually painted (kwi3-55l.16):
                                // proves the tab's Text.text is the project
                                // name itself, not merely that sortedWorkspaces
                                // carries it.
                                text: t ? t.text : null,
                                badgeVisible: bdg ? bdg.visible : false,
                                badgeText: bdg ? bdg.text : null })
            }
            host.emit("geom", tag + " " + JSON.stringify(out))
        }

        function rows(tag: string): void {
            host.emit("rows", tag + " " + JSON.stringify(bar.sortedWorkspaces))
        }

        function avail(tag: string): void {
            host.emit("avail", tag + " " + (Kwi3Client.available ? "1" : "0"))
        }

        // dotfiles-8luk: the ring window's own rect (screen coordinates) for
        // the focused tab, straight from the property the companion window
        // binds to.
        function ring(tag: string): void {
            host.emit("ring", tag + " " + JSON.stringify(bar.focusedTabScreenRect))
        }

        function plan(tag: string): void {
            host.emit("plan", tag + " " + JSON.stringify(bar.tabCellPlan))
        }

        // Invokes the REAL MouseArea.clicked handler on the Nth tab — the
        // same code path a real pointer click reaches.
        function clickTab(tag: string, index: int): void {
            var r = host.rootOf(bar)
            var clicks = []
            host.findAllByName(r, "wsTabClick", clicks)
            var ok = (index >= 0 && index < clicks.length)
            if (ok) { clicks[index].clicked(null) }
            host.emit("clicked", tag + " " + (ok ? "1" : "0"))
        }
    }

    Bar {
        id: bar
        screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    }
}
QMLEOF

        # Resolve to an absolute path FIRST: PATH is about to be replaced
        # wholesale for the launched process, so an unqualified "$QUICKSHELL"
        # would no longer resolve at all (measured — "env: quickshell: No
        # such file or directory" the first time this ran).
        QS_BIN6="$(command -v "$QUICKSHELL")"

        # kwi3-55l.16: a fixed census fixture (QS_CENSUS_CMD, the same
        # override Census.qml's own header describes) - "asahi" always
        # shows 2 working agents, so the badge (wsBadge, "●2") is ALWAYS
        # visible for that one tab, reproducing exactly the live shape that
        # made the name collapse to invisible (a badge Bar.qml's tab-width
        # calc never reserved room for).
        CENSUS_STUB="$TMP/census-stub.sh"
        cat > "$CENSUS_STUB" <<'CENSUSEOF'
#!/bin/sh
printf '[{"project":"asahi","total":2,"blocked":0,"working":2,"idle":0,"other":0}]\n'
CENSUSEOF
        chmod +x "$CENSUS_STUB"

        env -u I3SOCK -u SWAYSOCK -u WAYLAND_DISPLAY DISPLAY="$BAR_DPY" \
            PATH="$PBIN6" HOME="$TMP/home" KWI3SOCK="$SOCK_BAR" \
            QS_CENSUS_CMD="$CENSUS_STUB" \
            XDG_CONFIG_HOME="$CFG6" XDG_RUNTIME_DIR="$RUN6" XDG_CACHE_HOME="$CACHE6" \
            "$QS_BIN6" -p "$CFG6" >"$HOST6_LOG" 2>&1 &
        HOST6_PID=$!
        PIDS+=("$HOST6_PID")

        ipc6() {
            env XDG_CONFIG_HOME="$CFG6" XDG_RUNTIME_DIR="$RUN6" XDG_CACHE_HOME="$CACHE6" \
                "$QUICKSHELL" ipc --pid "$HOST6_PID" "$@" >/dev/null 2>&1
        }
        last6() { grep -a "KWI3TEST6 $1 $2 " "$HOST6_LOG" | tail -1 | sed "s/^.*KWI3TEST6 $1 $2 //"; }

        HOST6_UP=""
        for i in $(seq 1 60); do
            n="$(env XDG_CONFIG_HOME="$CFG6" XDG_RUNTIME_DIR="$RUN6" XDG_CACHE_HOME="$CACHE6" \
                     "$QUICKSHELL" ipc --pid "$HOST6_PID" show 2>/dev/null | grep -c 'bar6')"
            [ "${n:-0}" -gt 0 ] && { HOST6_UP=1; break; }
            sleep 0.25
        done

        if [ -z "$HOST6_UP" ]; then
            fail "the Bar host exposed the 'bar6' IPC target" "a bar6 target" "none"
            tail -40 "$HOST6_LOG" >&2
        else
            pass "the Bar host booted"

            scenario "0 workspaces reported: the bar shows none, no crash (edge case)"
            ipc6 call bar6 geometry "empty"
            sleep 0.3
            geom0="$(last6 geom empty)"
            case "$geom0" in
                *'"count":0'*) pass "zero tabs render with zero workspaces" ;;
                *) fail "zero tabs render with zero workspaces" '"count":0' "$geom0" ;;
            esac
            ipc6 call bar6 rows "stillup"
            sleep 0.2
            [ -n "$(last6 rows stillup)" ] && pass "the host is still alive (no crash) with zero workspaces" \
                || fail "the host is still alive with zero workspaces" "a rows reply" "(none)"

            scenario "3 workspaces: listed, focused one highlighted (AC1)"
            kill -USR1 "$BAR_RIG_PID"
            THREE=""
            for i in $(seq 1 30); do
                THREE="$(grep -a '^THREE ' "$BAR_RIG_LOG" | tail -1 | sed 's/^THREE //')"
                [ -n "$THREE" ] && break
                sleep 0.1
            done
            [ -n "$THREE" ] && pass "bar-driver.js created the three workspaces" \
                || fail "bar-driver.js created the three workspaces" "a THREE line" "(timed out)"

            got_rows=""
            for i in $(seq 1 40); do
                ipc6 call bar6 rows "r$i"
                sleep 0.15
                got_rows="$(last6 rows "r$i")"
                case "$got_rows" in *'"name":"ccc"'*) break ;; esac
            done
            case "$got_rows" in
                *'"name":"a"'*'"name":"bb"'*'"name":"ccc"'*)
                    pass "the bar lists all three of the rig's workspaces, in number order" ;;
                *) fail "the bar lists all three of the rig's workspaces" '"a","bb","ccc" in order' "$got_rows" ;;
            esac
            case "$got_rows" in
                *'"name":"a","number":1,"focused":true'*) pass "the focused workspace (a) is flagged focused" ;;
                *) fail "the focused workspace (a) is flagged focused" '"a" focused:true' "$got_rows" ;;
            esac

            scenario "whole-module tab geometry, height = one titlebar row (AC2)"
            BOOTGRID="$(grep -a '^BOOTGRID ' "$BAR_RIG_LOG" | head -1 | sed 's/^BOOTGRID //')"
            ipc6 call bar6 geometry "geom3"
            sleep 0.2
            geom3="$(last6 geom geom3)"
            ipc6 call bar6 plan "plan3"
            sleep 0.2
            plan3="$(last6 plan plan3)"
            [ "$(printf '%s' "$geom3" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const g=JSON.parse(d);console.log(String(g.count))})' 2>/dev/null)" = "3" ] \
                && pass "three tabs rendered" \
                || fail "three tabs rendered" "3" "$geom3"

            node -e '
const geom = JSON.parse(process.argv[1]);
const plan = JSON.parse(process.argv[2]);
const moduleW = 8, contentLeft = 8;
function ok(cond, name) { console.log((cond ? "PASS " : "FAIL ") + name); }
const cells = plan.cells;
ok(cells.length === 3, "plan has three cells");
// dotfiles-8luk: one cell of outer padding before the first tab.
const firstX = contentLeft + moduleW;
let x = firstX, allWhole = true, cum = true;
for (let i = 0; i < geom.tabs.length; i++) {
    const t = geom.tabs[i];
    if ((t.x - contentLeft) % moduleW !== 0) { allWhole = false; }
    if (t.width % moduleW !== 0) { allWhole = false; }
    if (t.x !== x) { cum = false; }
    x += t.width;
}
ok(allWhole, "every tab x and width is a whole multiple of moduleW from contentLeft");
ok(cum, "each tabs x is the running sum of the ones before it, starting one cell in from contentLeft");
ok(geom.tabs.length && geom.tabs[0].x === firstX, "the first tab starts one cell (outer padding) after contentLeft");
// kwi3-55l.16: cells is wants now, not a shared-out total (see Bar.qml own
// own tabCellPlan comment) - the invariant this used to check ("spare
// cells at the front") was really just a symptom of averaging sum(wants)
// across n tabs, which starved any tab whose want was above the average.
// The correct, and now load-bearing, invariant is that EVERY tab gets
// no less than what it asked for.
let noneStarved = true;
for (let i = 0; i < cells.length; i++) { if (cells[i] < plan.wants[i]) { noneStarved = false; } }
ok(noneStarved, "no tab has fewer cells than its own want (kwi3-55l.16)");
const sumWant = plan.wants.reduce((a, b) => a + b, 0);
const sumCells = cells.reduce((a, b) => a + b, 0);
ok(sumWant === sumCells, "cells equal wants exactly, so the totals agree too");
// AC2, first clause: the bar is exactly one titlebar row tall and reserves
// exactly what kwi3 serves. Checked against the RIG own grid.get answer
// (BOOTGRID, printed by the core itself), not only against Kwi3Grid - a
// Kwi3Grid that mis-read the field would otherwise agree with itself.
const boot = JSON.parse(process.argv[3]);
ok(geom.grid.rowHeight === boot.row, "Kwi3Grid.rowHeight equals the core grid.get row (" + boot.row + ")");
ok(geom.height === boot.row, "the bar height equals Kwi3Grid.rowHeight (" + geom.height + " vs " + boot.row + ")");
ok(geom.exclusiveZone === boot.reserve, "the bar exclusiveZone equals Kwi3Grid.reserve (" + geom.exclusiveZone + " vs " + boot.reserve + ")");
' "$geom3" "$plan3" "$BOOTGRID" > "$TMP/geom-check.out" 2>&1
            while IFS= read -r line; do
                case "$line" in
                    "PASS "*) pass "${line#PASS }" ;;
                    "FAIL "*) fail "${line#FAIL }" "true" "false" ;;
                esac
            done < "$TMP/geom-check.out"

            scenario "a workspace.focus notification from another client is followed within ~1s, well under the old 2s i3-msg timer (AC1)"
            kill -USR2 "$BAR_RIG_PID"
            followed=""
            for i in $(seq 1 10); do
                ipc6 call bar6 rows "f$i"
                sleep 0.1
                r="$(last6 rows "f$i")"
                case "$r" in *'"name":"bb","number":2,"focused":true'*) followed=1; break ;; esac
            done
            [ -n "$followed" ] && pass "the bar re-focused bb after a workspace.focus it did not send" \
                || fail "the bar followed the other client's workspace.focus" "bb focused:true" "$r"

            scenario "a click sends exactly one workspace.focus {num} (AC1)"
            : > "$BAR_RIG_LOG.clickmark"
            CCC_NUM="$(printf '%s' "$got_rows" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const rows=JSON.parse(d);console.log(String(rows.find(r=>r.name==="ccc").number))})' 2>/dev/null)"
            ipc6 call bar6 clickTab "click1" "2"
            sleep 0.2
            clicked="$(last6 clicked click1)"
            [ "$clicked" = "1" ] && pass "the click harness found a third tab to click" \
                || fail "the click harness found a third tab to click" "1" "$clicked"
            calls=""
            for i in $(seq 1 20); do
                calls="$(grep -a '^FOCUSCALLS ' "$BAR_RIG_LOG" | tail -1 | sed 's/^FOCUSCALLS //')"
                [ -n "$calls" ] && break
                sleep 0.1
            done
            n_calls="$(printf '%s' "${calls:-[]}" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{console.log(String(JSON.parse(d).length))})' 2>/dev/null)"
            [ "$n_calls" = "1" ] && pass "exactly one workspace.focus call reached the socket" \
                || fail "exactly one workspace.focus call reached the socket" "1" "$n_calls"
            case "$calls" in
                *"\"num\":$CCC_NUM"*) pass "the call's num matches the clicked tab (ccc)" ;;
                *) fail "the call's num matches the clicked tab (ccc)" "num:$CCC_NUM" "$calls" ;;
            esac

            # ---- shared checker for the scenarios below: every tab on the
            # grid the CORE says is current (its own grid.get answer), not
            # only on what Kwi3Grid mirrored of it.
            TABCHECK="$TMP/tabcheck.js"
            cat > "$TABCHECK" <<'JSEOF'
'use strict';
const [geomS, planS, gridS, ringS] = process.argv.slice(2);
const geom = JSON.parse(geomS), plan = JSON.parse(planS), grid = JSON.parse(gridS);
const ring = ringS ? JSON.parse(ringS) : undefined;
const mw = grid.module.w, left = grid.contentLeft;
function ok(cond, name) { console.log((cond ? 'PASS ' : 'FAIL ') + name); }
ok(geom.grid.moduleW === mw, 'Kwi3Grid.moduleW equals the core grid.get module.w (' + geom.grid.moduleW + ' vs ' + mw + ')');
ok(geom.height === grid.row, 'the bar height equals the core row (' + geom.height + ' vs ' + grid.row + ')');
ok(geom.exclusiveZone === grid.reserve, 'the bar exclusiveZone equals the core reserve (' + geom.exclusiveZone + ' vs ' + grid.reserve + ')');
ok(geom.count > 0 && geom.count === plan.cells.length, 'one tab per planned cell count (' + geom.count + ')');
// dotfiles-8luk: one cell of outer padding before the first tab; each tab is
// its label plus ONE trailing gap cell, so labels are exactly one cell apart
// and the last label is followed by one cell of outer padding.
let x = left + mw, whole = true, cum = true, match = true;
for (let i = 0; i < geom.tabs.length; i++) {
    const t = geom.tabs[i];
    if ((t.x - left) % mw !== 0 || t.width % mw !== 0) { whole = false; }
    if (t.x !== x) { cum = false; }
    if (t.width !== plan.cells[i] * mw) { match = false; }
    x += t.width;
}
ok(whole, 'every tab x and width is a whole multiple of ' + mw + ' from contentLeft ' + left);
ok(geom.tabs[0].x === left + mw, 'the first tab starts ONE cell of outer padding after contentLeft ' + left + ' (x=' + geom.tabs[0].x + ')');
ok(cum, 'tabs abut, starting one cell after contentLeft ' + left);
ok(match, 'every tab is exactly its planned cells x ' + mw + 'px');
// dotfiles-8luk: labels EXACTLY one cell apart. A tab's label box is the tab
// less its trailing gap cell, so the label boxes of neighbours are separated
// by that one cell and nothing else (no leading padding in the tab).
let oneGap = true, gapDetail = [];
for (let i = 0; i + 1 < geom.tabs.length; i++) {
    const a = geom.tabs[i], b = geom.tabs[i + 1];
    const gap = b.x - (a.x + a.width - mw);
    gapDetail.push(gap);
    if (gap !== mw) { oneGap = false; }
}
ok(oneGap, 'neighbouring tab labels are exactly ONE cell (' + mw + 'px) apart: ' + JSON.stringify(gapDetail));
// Independent of the plan: the painted label rows. A tab's cells must be its
// label's whole cells + exactly ONE (not derived from the tab's own width), and
// the painted gap between two neighbouring label rows is that one cell plus
// each row's centring slack (< one cell each) - so in [mw, 2*mw), never the
// two full cells the old label + 1 padding each side gave.
let cellsOk = true, cellDetail = [], gapsOk = true, gapPx = [];
for (let i = 0; i < geom.tabs.length; i++) {
    const t = geom.tabs[i];
    if (typeof t.rowW !== 'number' || t.truncated === true) { continue; }
    const want = Math.max(1, Math.ceil(t.rowW / mw - 0.001)) + 1;
    cellDetail.push(t.width / mw + '=' + want);
    if (t.width / mw !== want) { cellsOk = false; }
    if (i + 1 < geom.tabs.length && typeof geom.tabs[i + 1].rowX === 'number') {
        const g = geom.tabs[i + 1].rowX - (t.rowX + t.rowW);
        gapPx.push(g.toFixed(1));
        if (g < mw - 0.5 || g >= 2 * mw - 0.5) { gapsOk = false; }
    }
}
ok(cellsOk, 'each tab is its label\'s whole cells + exactly one cell: ' + cellDetail.join(' '));
ok(gapsOk, 'the painted gap between neighbouring label rows is one cell (>= ' + mw + ', < ' + 2 * mw + 'px): ' + gapPx.join(' '));
let painted = true;
for (let i = 0; i < geom.tabs.length; i++) {
    const t = geom.tabs[i];
    if (typeof t.textX !== 'number') { continue; }
    // the painted label lies inside [x, x + width - mw]: nothing of it in the gap cell
    if (t.textX < t.x - 0.5 || t.textX + t.textPainted > t.x + t.width - mw + 0.5) { painted = false; }
}
ok(painted, 'every painted label stays out of its trailing gap cell');
const last = geom.tabs[geom.tabs.length - 1];
ok((last.x + last.width - mw) + mw === last.x + last.width, 'the last tab is followed by one cell of outer padding (its trailing gap cell)');
// Focused highlight: label + one cell each side, on the grid, overhanging the
// tab; every unfocused tab paints nothing (transparent).
let fIdx = -1;
for (let i = 0; i < geom.tabs.length; i++) { if (geom.tabs[i].hlColor === '#152024') { fIdx = i; } }
ok(fIdx >= 0, 'exactly the focused tab paints the #152024 highlight (index ' + fIdx + ')');
if (fIdx >= 0) {
    const f = geom.tabs[fIdx];
    ok(f.hlX === f.x - mw && f.hlW === f.width + mw,
       'the focused highlight is its label + one cell each side: x ' + f.hlX + ' w ' + f.hlW + ' vs tab ' + f.x + '/' + f.width);
    ok((f.hlX - left) % mw === 0 && f.hlW % mw === 0, 'the focused highlight is on the grid');
    let quiet = true;
    for (let i = 0; i < geom.tabs.length; i++) { if (i !== fIdx && geom.tabs[i].hlColor !== '#00000000') { quiet = false; } }
    ok(quiet, 'unfocused tabs paint no highlight (transparent)');
    if (ring) {
        ok(ring.x === f.hlX && ring.w === f.hlW,
           'the ring window rect matches the highlight: ring x ' + ring.x + ' w ' + ring.w + ' vs ' + f.hlX + '/' + f.hlW);
    } else { ok(false, 'a ring rect was read'); }
}
// kwi3-55l.16: cells is wants now (Bar.qml's own tabCellPlan comment) -
// the old "non-increasing left to right" check only ever held because
// sum(wants) was averaged across every tab; the invariant that actually
// matters is that no tab's allocation falls below what it asked for.
let noneStarved = true;
for (let i = 0; i < plan.cells.length; i++) { if (plan.cells[i] < plan.wants[i]) { noneStarved = false; } }
ok(noneStarved, "no tab has fewer cells than its own want (kwi3-55l.16)");
JSEOF
            tabcheck() { # <label> <geom> <plan> <grid> [<ring>]
                local rtag="ring$RANDOM$RANDOM"
                ipc6 call bar6 ring "$rtag"
                sleep 0.3
                node "$TABCHECK" "$2" "$3" "$4" "$(last6 ring "$rtag")" > "$TMP/tabcheck.out" 2>&1
                while IFS= read -r line; do
                    case "$line" in
                        "PASS "*) pass "$1: ${line#PASS }" ;;
                        "FAIL "*) fail "$1: ${line#FAIL }" "true" "false" ;;
                        *) fail "$1: checker output" "PASS/FAIL lines" "$line" ;;
                    esac
                done < "$TMP/tabcheck.out"
            }

            scenario "a workspace name wider than the bar: capped to whole modules, label stays inside its tab (edge case)"
            bar_cmd long
            LONG=""
            for i in $(seq 1 30); do
                LONG="$(grep -a '^LONG ' "$BAR_RIG_LOG" | tail -1)"
                [ -n "$LONG" ] && break
                sleep 0.1
            done
            [ -n "$LONG" ] && pass "bar-driver.js created a 200-char workspace" \
                || fail "bar-driver.js created a 200-char workspace" "a LONG line" "(timed out)"
            geomL=""
            for i in $(seq 1 40); do
                ipc6 call bar6 geometry "gl$i"
                sleep 0.15
                geomL="$(last6 geom "gl$i")"
                case "$geomL" in *'"count":4'*) break ;; esac
            done
            sleep 0.2
            ipc6 call bar6 geometry "glfinal"
            ipc6 call bar6 plan "plfinal"
            sleep 0.3
            geomL="$(last6 geom glfinal)"
            planL="$(last6 plan plfinal)"
            tabcheck "long name" "$geomL" "$planL" "$BOOTGRID"
            node -e '
const geom = JSON.parse(process.argv[1]);
const plan = JSON.parse(process.argv[2]);
const mw = JSON.parse(process.argv[3]).module.w;
const barW = Number(process.argv[4]);
function ok(cond, name) { console.log((cond ? "PASS " : "FAIL ") + name); }
const cap = Math.floor(barW * 0.4 / mw);
ok(plan.wants.length === 4 && plan.wants[3] === cap,
   "the long name wants exactly the cap, floor(40% of " + barW + "px / " + mw + ") = " + cap + " cells (wants " + JSON.stringify(plan.wants) + ")");
let inside = true, padded = true, detail = [];
for (const t of geom.tabs) {
    if (typeof t.textX !== "number" || typeof t.textPainted !== "number") {
        inside = false; padded = false; detail.push("[" + t.x + "] label not found (wsTabText)"); continue;
    }
    if (typeof t.textX !== "number" || typeof t.textPainted !== "number") {
        inside = false; padded = false; detail.push("[" + t.x + "] label not found (wsTabText)"); continue;
    }
    const l = t.textX, r = t.textX + t.textPainted;
    detail.push("[" + t.x + "," + (t.x + t.width) + "] label [" + l.toFixed(1) + "," + r.toFixed(1) + "]");
    if (l < t.x || r > t.x + t.width) { inside = false; }
    if (l < t.x - 0.5 || r > t.x + t.width - mw + 0.5) { padded = false; }
}
ok(inside, "every painted label lies inside its own tab: " + detail.join(" "));
ok(padded, "every painted label keeps out of its trailing gap cell (dotfiles-8luk)");
const lt = geom.tabs[3];
ok(lt && lt.truncated === true, "the long label is elided (Text.truncated), not merely clipped");
' "$geomL" "$planL" "$BOOTGRID" "1024" > "$TMP/long-check.out" 2>&1
            while IFS= read -r line; do
                case "$line" in
                    "PASS "*) pass "long name: ${line#PASS }" ;;
                    "FAIL "*) fail "long name: ${line#FAIL }" "true" "false" ;;
                    *) fail "long name: checker output" "PASS/FAIL lines" "$line" ;;
                esac
            done < "$TMP/long-check.out"

            scenario "the grid changes under a live bar: height and tabs relayout on the new grid (edge case)"
            bar_cmd grid
            NEWGRID=""
            for i in $(seq 1 30); do
                NEWGRID="$(grep -a '^GRID ' "$BAR_RIG_LOG" | tail -1 | sed 's/^GRID //')"
                [ -n "$NEWGRID" ] && break
                sleep 0.1
            done
            case "$NEWGRID" in
                *'"module":{"w":10,"h":24}'*) pass "the core's grid really changed to 10x24" ;;
                *) fail "the core's grid really changed to 10x24" 'module {"w":10,"h":24}' "$NEWGRID" ;;
            esac
            relaid=""
            for i in $(seq 1 40); do
                ipc6 call bar6 geometry "gg$i"
                sleep 0.15
                g="$(last6 geom "gg$i")"
                case "$g" in *'"moduleW":10,'*) relaid=1; break ;; esac
            done
            [ -n "$relaid" ] && pass "Kwi3Grid under the bar picked up moduleW 10 (grid.changed)" \
                || fail "Kwi3Grid under the bar picked up moduleW 10" '"moduleW":10' "$g"
            sleep 0.2
            ipc6 call bar6 geometry "ggfinal"
            ipc6 call bar6 plan "pgfinal"
            sleep 0.3
            tabcheck "after grid.changed" "$(last6 geom ggfinal)" "$(last6 plan pgfinal)" "$NEWGRID"

            # ------------------------------------------------------------------
            # kwi3-55l.16 — the dotfiles $mod+p projects picker's own RPC pair
            # (Overlay.qml projectsSwitch/_kwi3ProjectsNew) must leave the BAR
            # tab showing the project's name, not a bare workspace number. The
            # rig below issues exactly the RPC calls the picker sends: a
            # pre-existing bare workspace ("alpha") is renamed to "alpha_1"
            # then the picker focuses the next index "alpha_2" (Shift+Enter's
            # chain, AC1c); a brand-new project with no live workspace
            # ("gamma") goes straight through workspace.focus (Enter's own
            # zero-workspaces branch). Checked two ways: core's own
            # workspace.list (PROJECT line) and the REAL rendered tab text
            # (wsTabText.text) through the same whole-module tab-sizing rule
            # every other name in this phase is held to.
            # ------------------------------------------------------------------
            scenario "kwi3-55l.16: the projects-picker RPC pair names workspaces after the project, and the bar tab shows that name"
            bar_cmd project
            PROJECT=""
            for i in $(seq 1 30); do
                PROJECT="$(grep -a '^PROJECT ' "$BAR_RIG_LOG" | tail -1 | sed 's/^PROJECT //')"
                [ -n "$PROJECT" ] && break
                sleep 0.1
            done
            [ -n "$PROJECT" ] && pass "the rig ran the projects-picker RPC pair" \
                || fail "the rig ran the projects-picker RPC pair" "a PROJECT line" "(timed out)"
            case "$PROJECT" in
                *'"name":"alpha_1"'*'"name":"alpha_2"'*'"name":"gamma"'*)
                    pass "core: workspace.list carries the project's own names (alpha_1, alpha_2, gamma), not bare numbers" ;;
                *) fail "core: workspace.list carries the project's own names" '"alpha_1","alpha_2","gamma"' "$PROJECT" ;;
            esac

            got_proj_rows=""
            for i in $(seq 1 40); do
                ipc6 call bar6 rows "proj$i"
                sleep 0.15
                got_proj_rows="$(last6 rows "proj$i")"
                case "$got_proj_rows" in *'"name":"gamma"'*) break ;; esac
            done
            case "$got_proj_rows" in
                *'"name":"alpha_1"'*) pass "the bar's own row list carries the renamed project tab (alpha_1)" ;;
                *) fail "the bar's own row list carries the renamed project tab (alpha_1)" '"name":"alpha_1"' "$got_proj_rows" ;;
            esac
            case "$got_proj_rows" in
                *'"name":"alpha_2"'*) pass "the bar's own row list carries the second indexed project tab (alpha_2)" ;;
                *) fail "the bar's own row list carries the second indexed project tab (alpha_2)" '"name":"alpha_2"' "$got_proj_rows" ;;
            esac
            case "$got_proj_rows" in
                *'"name":"gamma"'*'"focused":true'*) pass "the bar's own row list carries the brand-new project tab (gamma), focused" ;;
                *) fail "the bar's own row list carries the brand-new project tab (gamma), focused" '"name":"gamma",...,"focused":true' "$got_proj_rows" ;;
            esac

            ipc6 call bar6 geometry "projgeom"
            ipc6 call bar6 plan "projplan"
            sleep 0.3
            projgeom="$(last6 geom projgeom)"
            projplan="$(last6 plan projplan)"
            tabcheck "project names" "$projgeom" "$projplan" "$NEWGRID"
            node -e '
const geom = JSON.parse(process.argv[1]);
function ok(cond, name) { console.log((cond ? "PASS " : "FAIL ") + name); }
const texts = geom.tabs.map((t) => t.text);
ok(texts.includes("alpha_1"), "a tab is literally labelled alpha_1 (" + JSON.stringify(texts) + ")");
ok(texts.includes("alpha_2"), "a tab is literally labelled alpha_2 (" + JSON.stringify(texts) + ")");
ok(texts.includes("gamma"), "a tab is literally labelled gamma (" + JSON.stringify(texts) + ")");
ok(!texts.some((t) => /^[0-9]+$/.test(t || "")), "no project tab is a bare number (" + JSON.stringify(texts) + ")");
// kwi3-55l.16: the actual live symptom was not a number or a missing
// workspace, it was an ELIDED label ("...") sitting among short numbered
// tabs - a check on .text alone (above) cannot see that, since Text.text
// keeps the full string even when elide: Text.ElideRight is painting "..."
// over most of it. .truncated is what the widget itself reports. The
// 200-char fixture tab is excluded on purpose - THAT one is supposed to
// truncate (its own scenario asserts so), this is about the ordinary
// project names beside it.
for (const name of ["alpha_1", "alpha_2", "gamma"]) {
    const t = geom.tabs.find((x) => x.text === name);
    ok(t && t.truncated === false, "the " + name + " tab is NOT truncated (" + (t ? t.truncated : "tab not found") + ")");
}
' "$projgeom" > "$TMP/project-label-check.out" 2>&1
            while IFS= read -r line; do
                case "$line" in
                    "PASS "*) pass "project names: ${line#PASS }" ;;
                    "FAIL "*) fail "project names: ${line#FAIL }" "true" "false" ;;
                    *) fail "project names: checker output" "PASS/FAIL lines" "$line" ;;
                esac
            done < "$TMP/project-label-check.out"

            # ------------------------------------------------------------------
            # kwi3-55l.16 (Jan's own report, precise this time): the tab did not
            # show a bare number and did not go missing - it showed "…". Every
            # kwi3-path Kwi3Client.call had already been proven to reach the
            # wire with the right name (the scenario above); the label was
            # simply ELIDED, because tabCellPlan used to share sum(wants)
            # EQUALLY across every tab (a since-removed helper) rather than
            # giving each its own want - a short "9" and a longer "asahi" each
            # got the AVERAGE, so "asahi" had less width than its own
            # Text.implicitWidth and elide: Text.ElideRight painted "…" over
            # it. This scenario reconfigures the rig to Jan's OWN production
            # font/module (~/.dotfiles/kwi3/config.js: font 'Iosevka 16',
            # module [8, 21] - not the neutral "monospace"/8x21 default the
            # rest of this phase runs on, and not the 10x24 the earlier 'grid'
            # command left behind) and mixes a bare-numbered workspace with
            # several real project names, the exact shape of his session.
            # ------------------------------------------------------------------
            scenario "kwi3-55l.16: a project name beside a bare-numbered workspace is never elided, under Jan's own font/module (Iosevka 16, 8x21)"
            bar_cmd realistic
            REALISTIC=""
            for i in $(seq 1 40); do
                REALISTIC="$(grep -a '^REALISTIC ' "$BAR_RIG_LOG" | tail -1)"
                [ -n "$REALISTIC" ] && break
                sleep 0.1
            done
            [ -n "$REALISTIC" ] && pass "bar-driver.js reconfigured to Jan's font/module and created the mixed workspace set" \
                || fail "bar-driver.js reconfigured and created the mixed workspace set" "a REALISTIC line" "(timed out)"
            REALGRID="$(grep -a '^REALISTICGRID ' "$BAR_RIG_LOG" | tail -1 | sed 's/^REALISTICGRID //')"
            case "$REALGRID" in
                *'"family":"Iosevka"'*'"pixelSize":16'*)
                    pass "the core's grid.get reports Jan's own font (Iosevka 16)" ;;
                *) fail "the core's grid.get reports Jan's own font (Iosevka 16)" '"family":"Iosevka","pixelSize":16' "$REALGRID" ;;
            esac

            fontUp=""
            for i in $(seq 1 40); do
                ipc6 call bar6 geometry "font$i"
                sleep 0.15
                fg="$(last6 geom "font$i")"
                case "$fg" in *'"fontFamily":"Iosevka"'*'"fontPixelSize":16'*) fontUp=1; break ;; esac
            done
            [ -n "$fontUp" ] && pass "Kwi3Grid under the bar picked up Jan's font (Iosevka 16) via grid.changed" \
                || fail "Kwi3Grid under the bar picked up Jan's font" '"fontFamily":"Iosevka","fontPixelSize":16' "${fg:-}"

            if [ -n "$fontUp" ]; then
                # The census stub (QS_CENSUS_CMD) polls on its own timer -
                # wait for its first successful read to actually reach the
                # "asahi" badge before capturing geometry, rather than
                # racing it.
                censusUp=""
                for i in $(seq 1 40); do
                    ipc6 call bar6 geometry "cen$i"
                    sleep 0.15
                    cg="$(last6 geom "cen$i")"
                    case "$cg" in *'"text":"asahi"'*'"badgeVisible":true'*) censusUp=1; break ;; esac
                done
                [ -n "$censusUp" ] && pass "the census stub's badge (asahi, 2 working) reached the bar" \
                    || fail "the census stub's badge reached the bar" '"text":"asahi",...,"badgeVisible":true' "${cg:-}"

                sleep 0.2
                ipc6 call bar6 geometry "realgeom"
                ipc6 call bar6 plan "realplan"
                sleep 0.3
                realgeom="$(last6 geom realgeom)"
                realplan="$(last6 plan realplan)"
                tabcheck "realistic font" "$realgeom" "$realplan" "$REALGRID"
                node -e '
const geom = JSON.parse(process.argv[1]);
function ok(cond, name) { console.log((cond ? "PASS " : "FAIL ") + name); }
for (const name of ["9", "asahi", "kwi3", "dotfiles"]) {
    const t = geom.tabs.find((x) => x.text === name);
    ok(!!t, "a tab literally labelled " + JSON.stringify(name) + " exists (" + JSON.stringify(geom.tabs.map((x) => x.text)) + ")");
    ok(t && t.truncated === false, "the " + name + " tab is NOT truncated under Jan'"'"'s own font (" + (t ? t.truncated : "tab not found") + ")");
    ok(t && t.textPainted <= t.width, "the " + name + " tab'"'"'s painted label fits inside its own tab (" + (t ? t.textPainted : "?") + " <= " + (t ? t.width : "?") + ")");
}
// kwi3-55l.16 - the DECISIVE live symptom (Jan, after a bar restart): a
// project tab did not merely elide, it painted its census badge ALONE,
// the name text collapsed to nothing (_tabWantCells never reserved room
// for the badge). "asahi" carries a live QS_CENSUS_CMD stub badge
// (2 working agents) for exactly this reason: both the name and the
// badge must be visible together, neither one crowding the other out.
const asahi = geom.tabs.find((x) => x.text === "asahi");
ok(asahi && asahi.badgeVisible === true, "asahi'"'"'s census badge is visible (" + (asahi ? asahi.badgeVisible : "tab not found") + ")");
ok(asahi && asahi.badgeText === "●2", "asahi'"'"'s badge reads ●2 (two working agents), got " + JSON.stringify(asahi ? asahi.badgeText : null));
ok(asahi && asahi.text === "asahi" && asahi.truncated === false,
   "asahi'"'"'s NAME is still fully visible beside its badge, not swallowed by it (text=" + JSON.stringify(asahi ? asahi.text : null) + " truncated=" + (asahi ? asahi.truncated : "?") + ")");
' "$realgeom" > "$TMP/realistic-check.out" 2>&1
                while IFS= read -r line; do
                    case "$line" in
                        "PASS "*) pass "realistic font: ${line#PASS }" ;;
                        "FAIL "*) fail "realistic font: ${line#FAIL }" "true" "false" ;;
                        *) fail "realistic font: checker output" "PASS/FAIL lines" "$line" ;;
                    esac
                done < "$TMP/realistic-check.out"
            fi

            scenario "kwi3 restarts under a live bar: last rows kept while down, then refreshed (edge case)"
            ipc6 call bar6 rows "prekill"
            sleep 0.3
            PREKILL="$(last6 rows prekill)"
            case "$PREKILL" in
                *'"name":"a"'*) pass "rows before the restart hold the first rig's workspaces" ;;
                *) fail "rows before the restart hold the first rig's workspaces" '"a" among rows' "$PREKILL" ;;
            esac
            kill "$BAR_RIG_PID" 2>/dev/null
            for i in $(seq 1 50); do kill -0 "$BAR_RIG_PID" 2>/dev/null || break; sleep 0.1; done
            down=""
            for i in $(seq 1 30); do
                ipc6 call bar6 avail "down$i"
                sleep 0.15
                [ "$(last6 avail "down$i")" = "0" ] && { down=1; break; }
            done
            [ -n "$down" ] && pass "the bar's Kwi3Client saw kwi3 go away (available false)" \
                || fail "the bar's Kwi3Client saw kwi3 go away" "0" "$(last6 avail down1)"
            kept=1
            for i in 1 2 3; do
                sleep 0.3
                ipc6 call bar6 rows "down_rows$i"
                sleep 0.2
                [ "$(last6 rows "down_rows$i")" = "$PREKILL" ] || { kept=""; kept_got="$(last6 rows "down_rows$i")"; }
            done
            [ -n "$kept" ] && pass "the bar keeps its last workspace rows while kwi3 is down (3 samples over ~1.5s)" \
                || fail "the bar keeps its last workspace rows while kwi3 is down" "$PREKILL" "${kept_got:-}"

            BAR_RIG2_LOG="$TMP/bar-rig2.log"
            node "$BAR_DRIVER" "$RPC_SERVER" "$SOCK_BAR" "$BAR_CMD" restart >"$BAR_RIG2_LOG" 2>&1 &
            BAR_RIG_PID=$!
            PIDS+=("$BAR_RIG_PID")
            if ! wait_for_socket "$SOCK_BAR" 20; then
                fail "the restarted rig rebound $SOCK_BAR" "socket present" "missing"
                cat "$BAR_RIG2_LOG" >&2
            else
                pass "the restarted rig rebound the same socket"
                refreshed=""
                t0=$(date +%s%N)
                for i in $(seq 1 60); do
                    ipc6 call bar6 rows "up$i"
                    sleep 0.15
                    r="$(last6 rows "up$i")"
                    case "$r" in *'"name":"x"'*'"name":"yy"'*) refreshed=1; break ;; esac
                done
                ms=$(( ($(date +%s%N) - t0) / 1000000 ))
                [ -n "$refreshed" ] && pass "the bar refreshed to the new rig's workspaces (x, yy) ${ms}ms after the restart" \
                    || fail "the bar refreshed to the new rig's workspaces" '"x","yy"' "$r"
                case "$r" in
                    *'"name":"a"'*|*'"name":"bb"'*|*'"name":"ccc"'*)
                        fail "no stale row from the first rig survives the refresh" "only x, yy" "$r" ;;
                    *) pass "no stale row from the first rig survives the refresh" ;;
                esac
            fi
        fi
        kill "$HOST6_PID" 2>/dev/null
    fi
    kill "$BAR_RIG_PID" 2>/dev/null
fi
kill "$XVFB_PID" 2>/dev/null

# ============================================================================
# PHASE 7 (kwi3-234.18) — NO i3-msg is ever spawned under kwi3.
#
# sp004 Task 18 removed kwi3's i3 IPC socket, so on a kwi3 display every
# i3-msg fails at once - and Bar.qml's wsEventSub and mode feed restart
# themselves `onExited`, so an ungated i3 feed respawns i3-msg in a tight loop
# for the life of the bar (T15 saw exactly that with $I3SOCK unset). The fix
# gates the whole i3 feed on Kwi3Client.configured ($KWI3SOCK set), not on
# `available`, because the socket being DOWN is when the loop would spin. So
# the instrument is a STUB i3-msg on the bar's PATH that counts itself and
# fails the way a socketless i3-msg does (after a short pause, so the control
# below cannot spin a core):
#   7a  $KWI3SOCK set and NOTHING listening on it for ~2.5s (the window before
#       the first connect), then rpc-server.js comes up and the bar connects
#       (proved by its own workspace.list reaching the rig): the stub must
#       have run ZERO times across both halves;
#   7b  the control - the SAME Bar and stub with no $KWI3SOCK (an i3/sway
#       session): the stub IS run, so 7a's zero is not a stub nobody could
#       reach.
# ============================================================================

BAR7_DPY="${BAR7_DPY:-:96}"
scenario "PHASE 7 setup: a Bar with a counting stub i3-msg, under Xvfb $BAR7_DPY"
"$XVFB" "$BAR7_DPY" -screen 0 1024x300x24 >"$TMP/xvfb7.log" 2>&1 &
XVFB7_PID=$!
PIDS+=("$XVFB7_PID")
for i in $(seq 1 50); do dpy_up "$BAR7_DPY" && break; sleep 0.1; done
if ! dpy_up "$BAR7_DPY"; then
    fail "Xvfb $BAR7_DPY started" "display up" "not found"
else
    CFG7="$TMP/cfg7"; PBIN7="$TMP/pbin7"; I3MSG7_LOG="$TMP/i3msg7.log"
    mkdir -p "$CFG7" "$PBIN7"
    ln -sf "$COMMON_DIR" "$CFG7/Common"
    ln -sf "$BAR_QML" "$CFG7/Bar.qml"
    cat > "$CFG7/shell.qml" <<'QMLEOF'
import Quickshell
import QtQuick
import "./Common"

ShellRoot {
    Bar { screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null }
}
QMLEOF
    for t in sh cat sleep tr awk df grep sed cut head; do
        src="$(command -v "$t")" && ln -sf "$src" "$PBIN7/$t"
    done
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nsleep 0.5\necho "i3-msg (stub): no i3 socket" >&2\nexit 1\n' \
        "$I3MSG7_LOG" > "$PBIN7/i3-msg"
    chmod +x "$PBIN7/i3-msg"
    QS_BIN7="$(command -v "$QUICKSHELL")"
    i3msg_runs() { local n; n=$(grep -c . "$I3MSG7_LOG" 2>/dev/null); echo "${n:-0}"; }

    # start_bar7 <name> [KWI3SOCK=...]  ->  BAR7_PID
    start_bar7() {
        local name="$1"; shift
        mkdir -p "$TMP/run7-$name" "$TMP/cache7-$name"; chmod 700 "$TMP/run7-$name"
        env -u I3SOCK -u SWAYSOCK -u WAYLAND_DISPLAY -u KWI3SOCK "$@" DISPLAY="$BAR7_DPY" \
            PATH="$PBIN7" HOME="$TMP/home" \
            XDG_CONFIG_HOME="$CFG7" XDG_RUNTIME_DIR="$TMP/run7-$name" \
            XDG_CACHE_HOME="$TMP/cache7-$name" \
            "$QS_BIN7" -p "$CFG7" >"$TMP/qs7-$name.log" 2>&1 &
        BAR7_PID=$!
        PIDS+=("$BAR7_PID")
    }

    scenario "7a: under kwi3 (\$KWI3SOCK set), no i3-msg - neither before the socket answers nor after"
    SOCK7="$TMP/kwi3-p7.sock"
    : > "$I3MSG7_LOG"
    start_bar7 kwi3 KWI3SOCK="$SOCK7"
    sleep 2.5
    kill -0 "$BAR7_PID" 2>/dev/null && pass "the bar is up while \$KWI3SOCK names nothing yet" \
        || { fail "the bar is up while \$KWI3SOCK names nothing yet" "running" "exited"; tail -20 "$TMP/qs7-kwi3.log" >&2; }
    before="$(i3msg_runs)"
    KWI3_RIG_LOG_CALLS=1 node "$RPC_SERVER" "$SOCK7" >"$TMP/rig7.log" 2>&1 &
    RIG7_PID=$!
    PIDS+=("$RIG7_PID")
    connected=""
    if wait_for_socket "$SOCK7" 20; then
        for i in $(seq 1 60); do
            grep -aq '"method":"workspace.list"' "$TMP/rig7.log" && { connected=1; break; }
            sleep 0.1
        done
    fi
    [ -n "$connected" ] && pass "the bar connected once the socket came up (its workspace.list reached the rig)" \
        || fail "the bar connected once the socket came up" "a workspace.list CALL in the rig log" "$(tail -3 "$TMP/rig7.log")"
    sleep 2
    check7a="$(i3msg_runs)"
    [ "$before" = "0" ] && pass "no i3-msg was spawned while \$KWI3SOCK named nothing (~2.5s: the startup window)" \
        || fail "no i3-msg while \$KWI3SOCK named nothing" "0 runs" "$before runs: $(head -3 "$I3MSG7_LOG" | tr '\n' '|')"
    [ "$check7a" = "0" ] && pass "and none once Kwi3Client was connected (~2s more)" \
        || fail "no i3-msg once connected" "0 runs" "$check7a runs: $(head -3 "$I3MSG7_LOG" | tr '\n' '|')"
    kill "$BAR7_PID" 2>/dev/null; kill "$RIG7_PID" 2>/dev/null
    for i in $(seq 1 30); do kill -0 "$BAR7_PID" 2>/dev/null || break; sleep 0.1; done

    scenario "7b: control - no \$KWI3SOCK (i3/sway): the same stub IS spawned"
    : > "$I3MSG7_LOG"
    start_bar7 i3
    ran=""
    for i in $(seq 1 50); do [ "$(i3msg_runs)" -gt 0 ] && { ran=1; break; }; sleep 0.1; done
    [ -n "$ran" ] && pass "without \$KWI3SOCK the bar's i3 feed runs the stub i3-msg ($(i3msg_runs) run(s): $(head -1 "$I3MSG7_LOG"))" \
        || fail "without \$KWI3SOCK the bar's i3 feed runs i3-msg" ">=1 run" "0 runs"
    grep -q 'subscribe' "$I3MSG7_LOG" && pass "including an i3 subscription - the path 7a proves is off under kwi3" \
        || fail "the control includes an i3 subscription" "a -t subscribe run" "$(tr '\n' '|' < "$I3MSG7_LOG")"
    kill "$BAR7_PID" 2>/dev/null
    for i in $(seq 1 30); do kill -0 "$BAR7_PID" 2>/dev/null || break; sleep 0.1; done
fi
kill "$XVFB7_PID" 2>/dev/null

# ============================================================================
# PHASE 8 (kwi3-6oi) — a batched events.subscribe loses EVERY name when one
# is unknown to the server. Bar.qml/Kwi3Grid have subscribed to
# "workspace.urgent" (kwi3-11m) and "grid.changed" (kwi3-234.19) for a while
# now, and Kwi3Client._resubscribeAll() used to send every listened-for name
# in ONE events.subscribe call. core/rpc.js's rpcSubscribeValidate()
# (~l.497) refuses the WHOLE params array if any one name is unknown, so a
# kwi3 built before either of those events existed (Jan's own running 3392
# session until restarted, or the phone before its next deploy) silently
# lost workspace.focused/created/destroyed too, not just the new name. The
# fixture below plays that exact old server: it knows workspace.focused/
# created/destroyed and NOTHING newer, and enforces the same all-or-nothing
# rule core/rpc.js does. It is deliberately NOT a real kwi3 checkout —
# reproducing an exact pre-kwi3-11m rpc.js would mean pinning a commit tree
# here, and the behaviour under test (all-or-nothing on ONE bad name) is
# fully captured by a fixture this small.
# ============================================================================

scenario "PHASE 8 setup: an old-kwi3 fixture that has never heard of workspace.urgent"
# Deliberately choose a socket path with NOTHING listening on it yet, and
# start the harness (both listeners registered) BEFORE the fixture server
# ever exists - the same shape PHASE 7a uses. This is load-bearing, not
# cosmetic: on a fast local AF_UNIX connect it is possible for on()'s own
# immediate branch (`if (_sock && _sock.connected) { _subscribe([event]) }`)
# to win the race and send each name as its OWN single-item call before
# _resubscribeAll() ever runs - which would make this scenario pass by
# accident whether or not the real bug (the BATCH _resubscribeAll sends on
# every (re)connect) is fixed. Registering both listeners against a socket
# that is not there yet guarantees neither can be "already connected" when
# on() runs, so the connection that eventually succeeds is unambiguously the
# one _resubscribeAll() drives - the only path this task changes.
OLDFIXTURE="$TMP/fake-old-kwi3-server.js"
cat > "$OLDFIXTURE" <<'JSEOF'
'use strict';
// Throwaway fixture, NOT part of the kwi3 repo (kwi3-6oi): a stand-in for a
// kwi3 built before kwi3-11m/kwi3-234.19 - one that has never heard of
// "workspace.urgent" or "grid.changed". Mirrors core/rpc.js's real contract
// for the one thing this test cares about: rpcSubscribeValidate() checks
// the WHOLE params array before rpcSubscribeRun() ever runs, so one bad
// name in a BATCHED events.subscribe call refuses every name in that same
// call - never partial.
const net = require('net');
const fs = require('fs');
const sockPath = process.argv[2];
try { fs.unlinkSync(sockPath); } catch (e) { /* not there */ }

// The event vocabulary of the OLD server this fixture plays.
const KNOWN = { 'workspace.focused': true, 'workspace.created': true, 'workspace.destroyed': true };

const server = net.createServer((sock) => {
    const subs = {};
    let buf = '';
    const reply = (id, obj) => {
        if (id === undefined) { return; }   // notification: JSON-RPC 2.0 never replies
        sock.write(JSON.stringify(Object.assign({ jsonrpc: '2.0', id: id }, obj)) + '\n');
    };
    sock.on('data', (chunk) => {
        buf += chunk.toString('utf8');
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            if (!line.trim()) { continue; }
            let req;
            try { req = JSON.parse(line); } catch (e) { continue; }
            if (!req || typeof req !== 'object' || typeof req.method !== 'string') { continue; }
            const id = ('id' in req) ? req.id : undefined;
            if (req.method === 'events.subscribe') {
                const names = Array.isArray(req.params) ? req.params : [];
                const bad = names.find((n) => !KNOWN[String(n)]);
                if (bad !== undefined) {
                    reply(id, { error: { code: -32602, message: 'unknown event name: ' + bad } });
                    continue;               // all-or-nothing: nothing in this call is added
                }
                for (const n of names) { subs[n] = true; }
                reply(id, { result: {} });
            } else if (req.method === 'workspace.focus') {
                reply(id, { result: {} });
                if (subs['workspace.focused']) {
                    sock.write(JSON.stringify({ jsonrpc: '2.0', method: 'workspace.focused',
                        params: { id: 1, num: (req.params && req.params.num) || 0 } }) + '\n');
                }
            } else {
                reply(id, { result: null });
            }
        }
    });
});
server.listen(sockPath, () => { console.log(sockPath); });
JSEOF

SOCK_OLD="$TMP/kwi3-old.sock"
CFG8="$TMP/cfg8"
mkdir -p "$CFG8" "$TMP/run8" "$TMP/cache8"
ln -sf "$COMMON_DIR" "$CFG8/Common"
cat > "$CFG8/shell.qml" <<'QMLEOF'
import Quickshell
import Quickshell.Io
import QtQuick
import "./Common"

// Mirrors the real dotfiles Bar's own registration shape post kwi3-11m: a
// listener for the LONG-STANDING event (workspace.focused) and one for the
// NEWER event an older server does not know (workspace.urgent), both
// registered before any connection exists (KWI3SOCK names nothing yet when
// this boots - see the setup comment above).
ShellRoot {
    id: host
    function emit(name, payload) { console.log("KWI3TEST8 " + name + " " + payload) }

    property int focusedCount: 0
    property int urgentCount: 0

    Component.onCompleted: {
        Kwi3Client.on("workspace.focused", function (p) { host.focusedCount++ })
        Kwi3Client.on("workspace.urgent", function (p) { host.urgentCount++ })
    }

    IpcHandler {
        target: "kwi3test8"

        function avail(tag: string): void {
            host.emit("avail", tag + " " + (Kwi3Client.available ? "1" : "0"))
        }
        function counts(tag: string): void {
            host.emit("counts", tag + " " + host.focusedCount + " " + host.urgentCount)
        }
        function focus(tag: string, num: int): void {
            Kwi3Client.call("workspace.focus", { num: num }, function (err, res) {
                host.emit("focus-done", tag + " " + JSON.stringify({ err: err, res: res }))
            })
        }
    }
}
QMLEOF

HOST8_LOG="$TMP/qs-old.log"
env -u I3SOCK -u SWAYSOCK -u WAYLAND_DISPLAY -u DISPLAY \
    HOME="$TMP/home" KWI3SOCK="$SOCK_OLD" QT_QPA_PLATFORM=offscreen \
    XDG_CONFIG_HOME="$CFG8" XDG_RUNTIME_DIR="$TMP/run8" XDG_CACHE_HOME="$TMP/cache8" \
    "$QUICKSHELL" -p "$CFG8" >"$HOST8_LOG" 2>&1 &
HOST8_PID=$!
PIDS+=("$HOST8_PID")

ipc8() {
    env XDG_CONFIG_HOME="$CFG8" XDG_RUNTIME_DIR="$TMP/run8" XDG_CACHE_HOME="$TMP/cache8" \
        "$QUICKSHELL" ipc --pid "$HOST8_PID" "$@" >/dev/null 2>&1
}
last8() { grep -a "KWI3TEST8 $1 $2 " "$HOST8_LOG" | tail -1 | sed "s/^.*KWI3TEST8 $1 $2 //"; }
poll_avail8() { # <prefix> <expect 0|1> <timeout-s>
    local prefix="$1" expect="$2" n=$(( ${3:-10} * 5 )) i tag got
    for i in $(seq 1 "$n"); do
        tag="${prefix}_$i"
        ipc8 call kwi3test8 avail "$tag"
        sleep 0.15
        got="$(last8 avail "$tag")"
        [ "$got" = "$expect" ] && return 0
    done
    return 1
}

HOST8_UP=""
for i in $(seq 1 60); do
    n="$(env XDG_CONFIG_HOME="$CFG8" XDG_RUNTIME_DIR="$TMP/run8" XDG_CACHE_HOME="$TMP/cache8" \
             "$QUICKSHELL" ipc --pid "$HOST8_PID" show 2>/dev/null | grep -c 'kwi3test8')"
    [ "${n:-0}" -gt 0 ] && { HOST8_UP=1; break; }
    sleep 0.25
done

if [ -z "$HOST8_UP" ]; then
    fail "the old-kwi3 harness exposed the kwi3test8 IPC target" "a kwi3test8 target" "none"
    tail -40 "$HOST8_LOG" >&2
else
    pass "the old-kwi3 harness booted with both listeners registered against nothing listening yet"
    if poll_avail8 "pre" "0" 3; then
        pass "Kwi3Client.available is false before the old-kwi3 fixture exists"
    else
        fail "Kwi3Client.available is false before the fixture exists" "0" "$(last8 avail pre_1)"
    fi

    OLD_LOG_A="$TMP/old-a.log"
    node "$OLDFIXTURE" "$SOCK_OLD" >"$OLD_LOG_A" 2>&1 &
    OLD_PID=$!
    PIDS+=("$OLD_PID")

    if ! wait_for_socket "$SOCK_OLD" 10; then
        fail "old-kwi3 fixture bound $SOCK_OLD" "socket present" "missing"
        cat "$OLD_LOG_A" >&2
    elif ! poll_avail8 "up" "1" 10; then
        fail "Kwi3Client connects to the old-kwi3 fixture" "available=1" "$(last8 avail up_1)"
    else
        pass "old-kwi3 fixture bound its socket and Kwi3Client connected to it (the FIRST connect, driven entirely by _resubscribeAll - both listeners were registered before this socket existed)"

        scenario "an unknown name (workspace.urgent) in the subscribe set must not cost workspace.focused too (kwi3-6oi)"
        ipc8 call kwi3test8 focus "focus1" "2"
        got=""
        for i in $(seq 1 30); do
            ipc8 call kwi3test8 counts "c$i"
            sleep 0.15
            got="$(last8 counts "c$i")"
            case "$got" in "1 "*) break ;; esac
        done
        case "$got" in
            "1 "*) pass "workspace.focused still arrives even though workspace.urgent is unknown to this server" ;;
            *) fail "workspace.focused still arrives even though workspace.urgent is unknown to this server" \
                    "focusedCount=1" "counts=$got" ;;
        esac

        refused_n="$(grep -aic 'workspace.urgent' "$HOST8_LOG" | tr -d ' ')"
        [ "${refused_n:-0}" -ge 1 ] && pass "the refusal of the unknown name is observable client-side (not silently eaten)" \
            || fail "the refusal of the unknown name is observable client-side" ">=1 mention of workspace.urgent" "$refused_n"
        [ "${refused_n:-0}" -le 1 ] && pass "the refusal is logged ONCE, not spammed" \
            || fail "the refusal is logged once, not spammed" "<=1 mention" "$refused_n"

        scenario "reconnect to the same old server: still no spam, workspace.focused keeps working (idempotent resubscribe, kwi3-6oi)"
        kill "$OLD_PID" 2>/dev/null
        for i in $(seq 1 30); do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.1; done
        poll_avail8 "down" "0" 10 >/dev/null
        OLD_LOG_B="$TMP/old-b.log"
        node "$OLDFIXTURE" "$SOCK_OLD" >"$OLD_LOG_B" 2>&1 &
        OLD_PID=$!
        PIDS+=("$OLD_PID")
        if ! wait_for_socket "$SOCK_OLD" 15; then
            fail "the restarted old-kwi3 fixture rebound $SOCK_OLD" "socket present" "missing"
        elif ! poll_avail8 "reup" "1" 15; then
            fail "Kwi3Client reconnects to the restarted old-kwi3 fixture" "available=1" "$(last8 avail reup_1)"
        else
            pass "Kwi3Client reconnected to the restarted old-kwi3 fixture"
            ipc8 call kwi3test8 focus "focus2" "3"
            got2=""
            for i in $(seq 1 30); do
                ipc8 call kwi3test8 counts "d$i"
                sleep 0.15
                got2="$(last8 counts "d$i")"
                case "$got2" in "2 "*) break ;; esac
            done
            case "$got2" in
                "2 "*) pass "workspace.focused keeps arriving after a reconnect to the same old server" ;;
                *) fail "workspace.focused keeps arriving after a reconnect" "focusedCount=2" "counts=$got2" ;;
            esac
            refused_total="$(grep -aic 'workspace.urgent' "$HOST8_LOG" | tr -d ' ')"
            [ "${refused_total:-0}" -le 1 ] && pass "the refusal is still logged only once across the reconnect (no spam)" \
                || fail "the refusal is logged once total, not once per reconnect" "<=1 mention" "$refused_total"
        fi
    fi
fi
kill "$HOST8_PID" 2>/dev/null
kill "$OLD_PID" 2>/dev/null

# ============================================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
