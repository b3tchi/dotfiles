.pragma library

// CrashPolicy.js — the web tier's "renderer died, now what?" decision,
// factored out of WebTier.qml as a pure reducer so it can be table-tested
// without a renderer, a display, or a clock (dotfiles-f532; the
// `spawn-env-prefix` / `is-xrdp-display` seam pattern in
// `nushell/actions/preview`, exercised by preview-test's test 33).
//
// Nothing in here touches QML, Qt, time, or I/O: every function takes a
// state object and returns a NEW one plus, where relevant, an action for
// WebTier.qml to carry out. That is the whole point — the interesting
// behaviour of this guard is a state machine over a handful of events, and
// the events that make it misbehave (an OOM 20 s after a successful load)
// take 20 s of real renderer to produce and are therefore untestable in
// place.
//
// ── The problem this shape exists to solve ────────────────────────────────
//
// sp022 T5 shipped "renderer terminated -> reload ONCE -> else fallback
// text, never a dead window", with the budget refunded on
// LoadSucceededStatus. sp022 T10 then capped V8's old space at 256 MB,
// which made renderer OOM a REACHABLE state for ordinary html content — and
// an OOM *after* the page loads always follows a LoadSucceeded, so the
// budget was refunded on every iteration and the guard looped forever
// (dotfiles-f532).
//
// T10's own fix was `stableTimer`: refund only after a load has STOOD for
// 10 s. That bounds the fast loop (measured: 10 terminations in 45 s ->
// 2 then flat) but not the slow one — a page that idles past probation and
// only then exhausts the heap gets its budget refunded BEFORE the OOM, so
// the counter oscillates 0 -> 1 -> 0 and the loop runs at ~1 termination
// per 18 s indefinitely (measured on the unfixed file: 11 terminations in
// 200 s, dead periodic at 17.8 s, fallback never shown).
//
// The trap is that timing cannot separate the pathological case from the
// required one. A slow OOM loop at ~1/18 s and the four external SIGKILLs
// 14 s apart that R4 requires to ALL recover are statistically identical.
// A per-URL cap tight enough to stop the loop breaks R4; a cap loose enough
// for R4 lets the loop run for minutes; a rolling window fails the same way.
//
// ── What actually separates them: who killed the renderer ─────────────────
//
// MEASURED on Qt 6.11.1 / qml6, offscreen, ceiling active — every one of
// these is an observation, not a reading of the enum docs, which are
// misleading here:
//
//   V8 heap exhaustion (self-inflicted)  -> status=3 code=5      (13/13 obs)
//   external SIGKILL on the renderer     -> status=2 code=9
//   external SIGTERM on the renderer     -> status=2 code=61696
//   external SIGABRT on the renderer     -> status=1 code=64000
//
// status 3 is Qt's KilledTerminationStatus and 2 is CrashedTerminationStatus,
// which reads backwards until you see what Chromium means by them: "Killed"
// is *the process was terminated deliberately by itself or by the browser*
// (the V8 OOM handler calls TerminateCurrentProcessImmediately), while an
// unexpected signal death is "Crashed". That is exactly the distinction the
// guard needs — deterministic and self-inflicted (reloading reruns the same
// allocation and dies again) versus external and transient (reloading is
// very likely to work, and R3/R4 demand it does).
//
// So the primary discriminator is `status`, not `exitCode`: the code is
// logged and corroborates, but matching on it alone would make the guard
// hostage to one Chromium build's OOM exit code. Matching the status enum
// degrades in the safe direction — see the lifetime cap below, which is
// what makes "the guard can never loop" true even if this classification
// stops matching entirely on some future Qt.
//
// ── The three budgets, and where the line sits ────────────────────────────
//
// A termination is answered with a reload unless one of these is exhausted,
// in which case the tier shows its fallback text and stops for good (for
// this URL — a new sourceUrl resets everything, which is why re-previewing
// is always an escape):
//
//   OOM_BUDGET (1)       self-inflicted OOMs, NEVER refunded by probation.
//                        The second OOM on one URL means the content simply
//                        does not fit under the ceiling; reloading a third
//                        time cannot help. This is the budget that closes
//                        dotfiles-f532, and it makes the slow loop behave
//                        exactly like the fast one: two terminations, then
//                        the fallback.
//   TRANSIENT_BUDGET (1) sp022 T10's one free reload, refunded by
//                        onProbationElapsed once a load has stood 10 s.
//                        Bounds crash-on-load storms.
//   LIFETIME_BUDGET (8)  every termination of this URL whatever its cause,
//                        never refunded. Pure backstop: it is what makes
//                        "this guard cannot loop forever" unconditional
//                        rather than contingent on the OOM classification
//                        above still matching. Deliberately generous — R4's
//                        four SIGKILLs clear it twice over.
//
// Where the line sits, stated plainly: a single URL visit still recovers
// from up to eight non-OOM terminations spaced further apart than the 10 s
// probation. It gives up on the second self-inflicted OOM, on a second
// crash inside one probation window, or on the ninth termination of any
// kind. Everything past that is a keystroke away from a clean slate (any
// re-preview is a new sourceUrl).
//
// ── Backoff ───────────────────────────────────────────────────────────────
//
// Reloads are spaced 0, 1, 2, 4, 8, 16, 30, 30 s, keyed on the LIFETIME
// count — deliberately not on the transient one, because probation refunds
// the transient counter and the slow loop is precisely the case where
// probation keeps being satisfied. Its job is rate limiting, not stopping:
// with the OOM classification matching, the caps stop the loop at two
// terminations and the backoff never gets past its first step. It earns its
// keep only in the degraded case where the classification does not match,
// where it turns eight quick respawns into a visibly decaying series instead
// of eight seconds of renderer churn. A legitimate crash always still
// recovers, just marginally later.

var TRANSIENT_BUDGET = 1
var OOM_BUDGET = 1
var LIFETIME_BUDGET = 8

var BACKOFF_BASE_MS = 1000
var BACKOFF_CAP_MS = 30000

// Qt's RenderProcessTerminationStatus::KilledTerminationStatus. See the
// measurement table above for why this — and not the exit code — is the
// discriminator.
var KILLED_TERMINATION_STATUS = 3

// Fresh state for a URL nobody has crashed on yet.
function newState() {
    return { transient: 0, oom: 0, lifetime: 0 }
}

// True when the renderer was terminated deliberately (Chromium's own OOM
// path) rather than felled by an outside signal.
function isSelfInflicted(status) {
    return status === KILLED_TERMINATION_STATUS
}

// Delay before the nth reload of this URL (n = the lifetime termination
// count that triggered it, 1-based). First reload is immediate so a
// one-off crash recovers as fast as it always did.
function backoffMs(lifetime) {
    if (lifetime <= 1) {
        return 0
    }
    var ms = BACKOFF_BASE_MS
    for (var i = 2; i < lifetime; i++) {
        ms *= 2
        if (ms >= BACKOFF_CAP_MS) {
            return BACKOFF_CAP_MS
        }
    }
    return ms
}

// The decision. Returns the new state plus one of:
//   { action: "reload", delayMs: <n> }
//   { action: "fail", reason: "oom" | "transient" | "lifetime" }
function onTerminated(state, status, code) {
    var next = {
        transient: state.transient + 1,
        oom: state.oom + (isSelfInflicted(status) ? 1 : 0),
        lifetime: state.lifetime + 1
    }
    // Order matters only for the reason string reported to the user: the
    // OOM case is the one with an actionable remedy (raise the ceiling), so
    // it wins when several budgets blow at once.
    if (next.oom > OOM_BUDGET) {
        return { state: next, action: "fail", reason: "oom", delayMs: 0 }
    }
    if (next.transient > TRANSIENT_BUDGET) {
        return { state: next, action: "fail", reason: "transient", delayMs: 0 }
    }
    if (next.lifetime > LIFETIME_BUDGET) {
        return { state: next, action: "fail", reason: "lifetime", delayMs: 0 }
    }
    return { state: next, action: "reload", reason: "", delayMs: backoffMs(next.lifetime) }
}

// A load has now stood for the probation interval: refund the transient
// budget only. The OOM and lifetime counters are deliberately untouched —
// refunding them is the whole of the dotfiles-f532 bug.
function onProbationElapsed(state) {
    return { transient: 0, oom: state.oom, lifetime: state.lifetime }
}

// Fallback text for a URL the guard has given up on. Lives here rather than
// in the QML so the reason -> message mapping is table-testable too.
function failText(reason, url) {
    if (reason === "oom") {
        return "preview: web content exceeded the renderer memory ceiling twice"
            + " and was not reloaded again\n" + url
            + "\nraise it by setting QTWEBENGINE_CHROMIUM_FLAGS yourself"
    }
    return "preview: web content crashed and did not recover\n" + url
}
