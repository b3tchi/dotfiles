pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Kwi3Client (sp004 Task 12, kwi3-234.12; ft010 kwi3-jsonrpc-api) — the
// dotfiles' JSON-RPC 2.0 NDJSON client for kwi3's native API on $KWI3SOCK.
//
// Validated by poc003 (Quickshell 0.3.1, headless): a Socket + SplitParser is
// enough — no helper process, no i3-msg — but two things are load-bearing and
// non-obvious. First, `connected: true` as a static declarative binding NEVER
// fires the connect: the property has to be SET, imperatively, from
// Component.onCompleted (poc002 measured this the hard way — its rig never
// reported because the binding never ran). Second, a write needs `flush()`
// right after it, or it sits buffered.
//
// A THIRD thing, found driving this exact reconnect path against a real
// server that was killed and restarted (kwi3-234.12's own AC2): a single
// Socket object reused across repeated reconnects can go permanently silent
// after its second failed attempt — no `error`, no `connectionStateChanged`,
// forever — even once the target is genuinely listening again. Measured over
// dozens of kill/restart cycles: the first automatic retry always resolves
// (success or a clean error), but a SECOND retry on that SAME Socket instance
// sometimes never resolves either way. Recreating the Socket object for every
// connection attempt (a Component instantiated fresh each time, the previous
// instance explicitly destroyed) has not reproduced the hang in the same
// stress run; whatever the underlying cause, a brand new object cannot carry
// over whatever state the stuck one was in.
//
// Absent $KWI3SOCK — a real i3 or sway session, which is every session this
// spec does not touch — this singleton never creates a Socket at all: no
// connection attempt, no error, no reconnect timer ever starts. `available`
// simply stays false, which is what every dotfiles consumer's own i3/sway
// fallback is keyed on.
Singleton {
    id: client

    // ---- ft010 client surface ----------------------------------------
    readonly property bool available: _sock !== null && _sock.connected

    // call(method, params, cb) — cb(error, result), exactly one of the two
    // non-null. `params` may be omitted (undefined) for a no-params method.
    // Never throws and never requires the caller to check `available` first:
    // with no socket, or mid-reconnect, cb still fires (asynchronously, so a
    // caller can always treat this as "answers later") with an error object
    // and a null result.
    function call(method, params, cb) {
        if (!_enabled || !_sock || !_sock.connected) {
            if (cb) {
                Qt.callLater(function () {
                    cb({ code: -32098, message: "kwi3 not connected" }, null)
                })
            }
            return
        }
        var id = client._nextId++
        if (cb) { client._pending[id] = cb }
        client._send({ jsonrpc: "2.0", id: id, method: method, params: params })
    }

    // on(event, cb) — cb(params) for every notification named `event`, for
    // this singleton's lifetime (there is no `off`: every dotfiles consumer
    // registered so far — Kwi3Grid — subscribes once and keeps listening).
    // Subscribes immediately if already connected; every future (re)connect
    // re-subscribes every event any caller has ever asked for, in
    // _resubscribeAll() below, so a reconnect after the server restarts
    // needs nothing from the caller.
    function on(event, cb) {
        if (!client._listeners[event]) { client._listeners[event] = [] }
        client._listeners[event].push(cb)
        if (_sock && _sock.connected) { client._subscribe([event]) }
    }

    // ---- internal state -------------------------------------------------
    readonly property string _socketPath: Quickshell.env("KWI3SOCK") || ""
    readonly property bool _enabled: _socketPath !== ""

    property var _pending: ({})     // request id -> callback
    property var _listeners: ({})   // event name -> [callback, ...]
    property int _nextId: 1

    // The live connection attempt, recreated from scratch (see the file
    // header) every time _connect() runs — never the same object twice.
    property var _sock: null

    // Reconnect backoff (edge case: kill-and-restart must reconnect and
    // resubscribe "within the backoff", not on a fixed poll). Resets to the
    // floor on every successful connect.
    property int _backoffMs: 200
    readonly property int _minBackoffMs: 200
    readonly property int _maxBackoffMs: 5000

    Component {
        id: _sockComponent
        Socket {
            parser: SplitParser {
                splitMarker: "\n"
                onRead: data => client._handleLine(data)
            }
            onConnectionStateChanged: {
                if (connected) {
                    client._backoffMs = client._minBackoffMs
                    client._resubscribeAll()
                } else {
                    client._failAllPending("kwi3 connection lost")
                    client._scheduleReconnect()
                }
            }
            onError: error => {
                client._failAllPending("kwi3 socket error: " + error)
                client._scheduleReconnect()
            }
        }
    }

    // Tears down whatever attempt exists (if any) and starts a fresh one.
    // Called from Component.onCompleted (the first connect) and from the
    // reconnect timer (every retry) — never anywhere else, so there is
    // exactly one place a Socket for this client is ever created.
    function _connect() {
        if (!client._enabled) { return }
        if (client._sock) {
            var old = client._sock
            client._sock = null
            old.destroy()
        }
        client._sock = _sockComponent.createObject(client, { path: client._socketPath })
        client._sock.connected = true
    }

    function _send(obj) {
        if (!client._sock) { return }
        client._sock.write(JSON.stringify(obj) + "\n")
        client._sock.flush()
    }

    function _subscribe(names) {
        if (!names.length) { return }
        // A notification (no "id"): core/rpc.js executes it and does not
        // reply — there is nothing to dispatch on the way back.
        client._send({ jsonrpc: "2.0", method: "events.subscribe", params: names })
    }

    function _resubscribeAll() {
        client._subscribe(Object.keys(client._listeners))
    }

    // A dropped connection must not leak a pending call forever — the same
    // "no leak of pending callbacks" edge case that governs 1000 calls in a
    // row also applies to a connection that dies mid-flight.
    function _failAllPending(why) {
        var ids = Object.keys(client._pending)
        for (var i = 0; i < ids.length; i++) {
            var cb = client._pending[ids[i]]
            delete client._pending[ids[i]]
            if (cb) { cb({ code: -32097, message: why }, null) }
        }
    }

    function _handleLine(line) {
        if (line.trim() === "") { return }     // SplitParser can hand blanks
        var msg
        try {
            msg = JSON.parse(line)
        } catch (err) {
            return                              // not this client's problem to raise
        }
        if (!msg || typeof msg !== "object") { return }

        if ("id" in msg && msg.id !== null) {
            // A reply. Dispatch by id — the two-calls-in-flight-answered-
            // out-of-order edge case is exactly why this is a map keyed on
            // id, not a queue.
            var cb = client._pending[msg.id]
            if (!cb) { return }                 // stale/unknown id: ignore
            delete client._pending[msg.id]
            if (msg.error) { cb(msg.error, null) } else { cb(null, msg.result) }
            return
        }
        if (typeof msg.method === "string") {
            var cbs = client._listeners[msg.method]
            if (!cbs) { return }
            for (var i = 0; i < cbs.length; i++) { cbs[i](msg.params) }
        }
    }

    // Idempotent per outstanding retry: `connectionStateChanged` (connected
    // -> false) and `error` fire TOGETHER for one underlying disconnect —
    // observed back to back for the same failure, not just in theory — and
    // without this guard each of the two calls this once per failure,
    // silently doubling the backoff twice per real event instead of once.
    // The guard is "a retry is already ticking down", not a dedup on the
    // failure itself, so a SECOND, genuinely later failure (the retry
    // itself not landing) still reschedules normally once the first timer
    // has fired.
    function _scheduleReconnect() {
        if (!client._enabled) { return }
        if (_reconnectTimer.running) { return }
        _reconnectTimer.interval = client._backoffMs
        client._backoffMs = Math.min(client._backoffMs * 2, client._maxBackoffMs)
        _reconnectTimer.restart()
    }

    Timer {
        id: _reconnectTimer
        interval: client._backoffMs
        repeat: false
        onTriggered: {
            if (client._enabled && (!client._sock || !client._sock.connected)) {
                client._connect()
            }
        }
    }

    Component.onCompleted: {
        // The imperative kick poc003 found necessary — see the file header.
        client._connect()
    }
}
