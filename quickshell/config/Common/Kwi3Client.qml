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

    // True for the whole life of a kwi3 session - $KWI3SOCK is set - whether
    // or not the socket is answering right now; false on every i3/sway
    // session. This, not `available`, is what an i3-msg fallback must be
    // gated on (kwi3-234.18): since sp004 Task 18 a kwi3 display has no i3
    // IPC socket at all, so an i3-msg started while Kwi3Client is merely
    // DISCONNECTED - before its first connect, or across a kwi3 restart - can
    // only fail at once, and a Process whose onExited restarts it then
    // respawns i3-msg in a tight loop for as long as the socket is down.
    readonly property bool configured: _enabled

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

    // kwi3-6oi: event names the server has ever refused (unknown method
    // param), so a refusal is logged once for the life of this singleton,
    // not once per (re)connect - _resubscribeAll() retries every name on
    // every reconnect regardless, in case a redeployed kwi3 now knows it.
    property var _refusedSubscribes: ({})

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

    // kwi3-6oi: ONE events.subscribe call per name, never a batch. core/
    // rpc.js's rpcSubscribeValidate() (~l.497) refuses the WHOLE params
    // array if any single name in it is unknown, and _resubscribeAll()
    // below sends every event any caller has ever asked for in one shot on
    // every (re)connect - so a single newer name (workspace.urgent,
    // kwi3-11m; grid.changed, kwi3-234.19) cost every other subscription
    // too against a kwi3 that predates it (Jan's own running session until
    // restarted, or the phone before its next deploy). This is the fix that
    // helps against an already-deployed older kwi3 - the server stays
    // strict on purpose (docs/notes/ft010.md's contract), so the client is
    // what has to stop batching.
    //
    // Sent as a REQUEST (an id), not the old best-effort notification: a
    // bare notification gets no reply either way (JSON-RPC 2.0 - no
    // Response object for a notification), so a refusal could never be
    // observed to log it. `call()` already does the right thing with no
    // socket / mid-reconnect (fires the callback async with an error, no
    // send attempted) so this is safe to call from _resubscribeAll() the
    // moment `connected` flips true.
    //
    // Idempotency: a name already held is a no-op on the server
    // (core/rpc.js's own doc comment on events.subscribe - "subscribing to
    // a name already held just leaves the set as it is"), and every
    // (re)connect is a NEW server-side connection object with its own empty
    // subscription set, so re-sending the full name list on each reconnect
    // never double-registers a name on one connection and never causes a
    // notification to be dispatched twice for one event.
    function _subscribeOne(name) {
        client.call("events.subscribe", [name], function (err) {
            if (err && !client._refusedSubscribes[name]) {
                client._refusedSubscribes[name] = true
                console.warn("Kwi3Client: server refused events.subscribe for '" +
                    name + "': " + err.message +
                    " (older kwi3? other event subscriptions are unaffected)")
            }
        })
    }

    function _subscribe(names) {
        for (var i = 0; i < names.length; i++) {
            client._subscribeOne(names[i])
        }
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
