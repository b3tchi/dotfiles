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
# server this script writes to $TMP and discards; every other scenario here
# is real core.
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

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
scenario() { printf '\n[%s]\n' "$1"; }

for tool in "$QUICKSHELL" node; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (QUICKSHELL= to override)" >&2; exit 1; }
done
[ -d "$COMMON_DIR" ] || { echo "FATAL: $COMMON_DIR not a directory" >&2; exit 1; }
for f in Kwi3Client.qml Kwi3Grid.qml qmldir; do
  [ -r "$COMMON_DIR/$f" ] || { echo "FATAL: $COMMON_DIR/$f missing" >&2; exit 1; }
done
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
