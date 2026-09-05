#!/usr/bin/env nu
# infinifu-worker — the Pi worker message bus (ft014 / sp028).
#
# This file currently carries the PROTOCOL only: envelope schemas, the caps,
# and the worker state machine. The commands that move bytes (`spawn`, `send`,
# `wait`, `ack`, `status`, `inspect`, `resume`, `accept`, `stop`) land in
# sp028 T2-T4 on top of these definitions. Keeping the contract in one place
# and validating BEFORE any IO is the point: a malformed envelope must never
# reach a runtime directory, and an illegal state edge must never be persisted.
#
# Nushell per adr0001/adr0002 — this is workflow tooling handling structured
# data, and the compiled-helper path is explicitly excluded by sp028.
#
# TRANSPORT BOUNDARY — read this before adding a command.
#
# tmux hosts and displays worker processes. It is NOT the bus. Nothing here
# may use `tmux send-keys`, `tmux wait-for`, pane options, or `display-message`
# to carry a message, a completion signal, a status, or any coordination state.
# Those verbs put orchestration state in a place that cannot be versioned,
# sequenced, addressed, or replayed after a crash, and `send-keys` in
# particular types text into whatever now occupies a stale target — a shell,
# somebody else's editor. Messages travel as envelopes under
# $XDG_RUNTIME_DIR/infinifu-worker/<run-id>/<worker-uid>/ and nowhere else.
# The only legitimate tmux calls are window/process lifecycle: new-window,
# list-windows, kill-window.

# ------------------------------------------------------------------ constants

# Bumped only for an incompatible envelope change. A reader that meets an
# unknown version fails closed rather than guessing at the fields.
export const PROTOCOL_VERSION = 1

# Envelope cap: a bus message is an address plus a pointer, never a payload of
# record. Anything approaching this size means prose is being copied that
# belongs in bd, Git, or AKM.
export const MAX_ENVELOPE_BYTES = 65536

# Summary cap: what the initiator reads inline. Detail stays in the visible
# worker window and the Pi JSONL.
export const MAX_SUMMARY_BYTES = 4096

export const ENVELOPE_KINDS = ["inbox" "result" "error"]

# Persisted worker states.
export const WORKER_STATES = [
    "created"
    "running"
    "waiting_human"
    "blocked"
    "failed"
    "complete"
    "protocol_error"
    "accepted"
    "stopped"
]

# `unknown` is an OBSERVATIONAL verdict — "the evidence does not say" — and is
# deliberately absent from WORKER_STATES. Per adr0017 it must never be
# persisted, reported by a worker, or used to license cleanup: missing process,
# bus, or transcript evidence is a reason to look again, not to delete.
export const OBSERVATIONAL_VERDICTS = ["unknown"]

# Statuses a worker may report in a result envelope. `accepted` is the
# initiator's verdict on the work and `stopped` is an external act, so neither
# is something a worker can claim about itself.
export const RESULT_STATUSES = ["complete" "waiting_human" "blocked" "failed"]

# Stages whose entire work content is a bd ticket id (ft013). The worker
# resolves its contract with `bd show <id>`; the payload never carries task
# prose, because a copied body is a second source of truth that drifts from bd
# the moment the task is updated.
export const WORK_STAGES = ["work-do" "work-audit" "work-merge"]

# Fields that betray a copied task body in a work-stage payload.
const WORK_PAYLOAD_ALLOWED = ["stage" "task"]

const ENVELOPE_REQUIRED = ["protocol" "sequence" "run" "uid" "kind" "created" "payload"]

# ------------------------------------------------------------ state machine

# The legal edges, exhaustively. Anything not listed here is illegal, so the
# table is the contract rather than a hint: a new state cannot be smuggled in
# by an `if` somewhere in the IO layer.
#
# Shape notes:
#   - `created` may only start or be torn down; it never reports an outcome.
#   - every outcome state may resume to `running` EXCEPT `accepted`, which is
#     the end of the line, and `stopped`, which was an explicit teardown.
#   - `complete → accepted` is the only edge into `accepted`. That is what
#     makes acceptance mean "a human or a successful merge said so" instead of
#     "the worker said it was done".
export def transitions []: nothing -> table<from: string, to: string> {
    [
        [from, to];

        ["created", "running"]
        ["created", "stopped"]
        ["created", "protocol_error"]

        ["running", "waiting_human"]
        ["running", "blocked"]
        ["running", "failed"]
        ["running", "complete"]
        ["running", "protocol_error"]
        ["running", "stopped"]

        ["waiting_human", "running"]
        ["waiting_human", "failed"]
        ["waiting_human", "protocol_error"]
        ["waiting_human", "stopped"]

        ["blocked", "running"]
        ["blocked", "failed"]
        ["blocked", "protocol_error"]
        ["blocked", "stopped"]

        ["failed", "running"]
        ["failed", "stopped"]

        ["complete", "accepted"]
        ["complete", "running"]
        ["complete", "stopped"]

        ["protocol_error", "running"]
        ["protocol_error", "stopped"]
    ]
}

export def legal-transition? [from: string, to: string]: nothing -> bool {
    (transitions | where from == $from and to == $to | length) > 0
}

# Reject an illegal edge with a reason naming both ends. Fails closed: an
# unrecognised state is rejected before the pair is even considered, so a typo
# cannot silently behave like a fresh state with no edges.
export def validate-transition [from: string, to: string] {
    for state in [$from $to] {
        if $state in $OBSERVATIONAL_VERDICTS {
            error make {msg: $"'($state)' is an observational verdict, not a persisted state: it can never be a transition endpoint \(adr0017)"}
        }
        if $state not-in $WORKER_STATES {
            error make {msg: $"unknown worker state '($state)': not one of ($WORKER_STATES | str join ', ')"}
        }
    }
    if not (legal-transition? $from $to) {
        error make {msg: $"illegal transition ($from) -> ($to)"}
    }
}

# ------------------------------------------------------------- envelope size

# Size is measured on the serialized form, because that is what the cap is
# protecting: the bytes actually written to the runtime directory and read
# back by an initiator.
export def envelope-bytes [envelope: record]: nothing -> int {
    $envelope | to json --raw | into binary | bytes length
}

def text-bytes [value: string]: nothing -> int {
    $value | into binary | bytes length
}

# --------------------------------------------------------- payload contracts

def validate-inbox-payload [payload: record] {
    if "stage" not-in ($payload | columns) {
        error make {msg: "inbox payload must name its stage"}
    }
    let stage = $payload.stage
    let fields = ($payload | columns)

    if $stage in $WORK_STAGES {
        if "task" not-in $fields {
            error make {msg: $"work-stage payload for '($stage)' must carry its bd task id"}
        }
        let extra = ($fields | where {|f| $f not-in $WORK_PAYLOAD_ALLOWED })
        if ($extra | is-not-empty) {
            error make {msg: $"work-stage payload for '($stage)' may carry only stage and task; found ($extra | str join ', '). The worker resolves its contract with `bd show`, so a copied task body is a second source of truth"}
        }
    } else {
        if "task" in $fields {
            error make {msg: $"AKM-stage payload for '($stage)' must not carry a bd task id: non-work stages receive direct instructions and artifact ids"}
        }
        if "instructions" not-in $fields {
            error make {msg: $"AKM-stage payload for '($stage)' must carry direct instructions"}
        }
    }
}

def validate-result-payload [payload: record] {
    let fields = ($payload | columns)
    for required in ["status" "summary" "window" "session" "resume"] {
        if $required not-in $fields {
            error make {msg: $"result payload must carry ($required)"}
        }
    }

    let status = $payload.status
    if $status in $OBSERVATIONAL_VERDICTS {
        error make {msg: $"'($status)' is an observational verdict and can never be reported as a result status \(adr0017)"}
    }
    if $status == "accepted" {
        error make {msg: "a worker cannot report status 'accepted': acceptance is the initiator's verdict, granted only after a completion is reviewed or a merge succeeds"}
    }
    if $status not-in $RESULT_STATUSES {
        error make {msg: $"unknown result status '($status)': not one of ($RESULT_STATUSES | str join ', ')"}
    }

    if (text-bytes $payload.summary) > $MAX_SUMMARY_BYTES {
        error make {msg: $"result summary exceeds the 4 KiB summary cap; detail belongs in the worker window and the Pi transcript, not the envelope"}
    }

    # ft013: completion is gated on the stage's own validation. A worker that
    # finished its turn without a verdict is `blocked`, not `complete`.
    if $status == "complete" {
        let verdict = ($payload | get -o validation)
        if ($verdict | is-empty) {
            error make {msg: "a 'complete' result must carry its validation verdict: completion cannot be reported before the stage's required validation passes"}
        }
    }
}

def validate-error-payload [payload: record] {
    for required in ["code" "detail"] {
        if $required not-in ($payload | columns) {
            error make {msg: $"error payload must carry ($required)"}
        }
    }
}

# ------------------------------------------------------------- envelope gate

# The single gate every envelope passes before it is written or acted on.
# Rejections name the offending field so an operator reading a log knows what
# to fix without reverse-engineering the validator.
export def validate-envelope [envelope: record] {
    let fields = ($envelope | columns)

    for required in $ENVELOPE_REQUIRED {
        if $required not-in $fields {
            error make {msg: $"envelope is missing required field '($required)'"}
        }
    }

    if $envelope.protocol != $PROTOCOL_VERSION {
        error make {msg: $"unknown protocol version ($envelope.protocol): this build speaks version ($PROTOCOL_VERSION) only"}
    }

    if $envelope.kind not-in $ENVELOPE_KINDS {
        error make {msg: $"unknown envelope kind '($envelope.kind)': not one of ($ENVELOPE_KINDS | str join ', ')"}
    }

    if ($envelope.sequence | describe) != "int" {
        error make {msg: "envelope sequence must be an integer"}
    }
    if $envelope.sequence < 0 {
        error make {msg: $"envelope sequence must be non-negative, got ($envelope.sequence)"}
    }

    for addressed in ["run" "uid" "created"] {
        if ($envelope | get $addressed | is-empty) {
            error make {msg: $"envelope field '($addressed)' must not be empty"}
        }
    }

    let size = (envelope-bytes $envelope)
    if $size > $MAX_ENVELOPE_BYTES {
        error make {msg: $"envelope is ($size) bytes, over the 64 KiB envelope cap: a bus message addresses work, it does not carry it"}
    }

    match $envelope.kind {
        "inbox" => { validate-inbox-payload $envelope.payload }
        "result" => { validate-result-payload $envelope.payload }
        "error" => { validate-error-payload $envelope.payload }
    }
}

# A worker whose agent settled without calling the typed result tool has NOT
# completed — there is no verdict, no summary, no resume evidence, only an idle
# prompt. Inferring success from an idle pane or an exited process is the
# failure this envelope exists to prevent, so the absence of a result is itself
# reported, as a protocol error.
export def settled-without-result [run: string, uid: string, sequence: int, created: string]: nothing -> record {
    {
        protocol: $PROTOCOL_VERSION
        sequence: $sequence
        run: $run
        uid: $uid
        kind: "error"
        created: $created
        payload: {
            code: "protocol_error"
            detail: "agent settled without calling the typed result tool; completion is never inferred from an idle prompt, an exited pane, or assistant prose"
        }
    }
}

# ============================================================== message bus
#
# Layout, one directory per addressee:
#
#   $XDG_RUNTIME_DIR/infinifu-worker/<run-id>/<worker-uid>/
#       inbox/<sequence>.json     messages to the worker
#       outbox/<sequence>.json    results from the worker
#       outbox/<sequence>.ack     delivery receipt, written by the initiator
#
# Addressing is the directory path, which is what makes cross-run isolation
# structural rather than a filter someone can forget: a reader scoped to
# run-1 cannot form a path into run-2.
#
# Two durability rules hold everything together:
#
#   1. Every envelope is written to a scratch name and renamed into place.
#      rename(2) is atomic, so a reader sees the whole envelope or no file at
#      all. An interrupted write leaves a `.tmp.` file, which no reader looks
#      at.
#   2. A sequence slot is claimed with link(2), which fails if the target
#      exists. Two writers racing for the same slot cannot both win, so the
#      loser retries instead of silently overwriting the winner.
#
# `wait` is deliberately non-destructive: it reports the oldest unacknowledged
# result and leaves it in place. Only `ack` marks it delivered, so an initiator
# that dies between reading and acknowledging sees the same result again.
# Acknowledgement is a delivery receipt and nothing more — it never means the
# work was accepted.

const BUS_DIRNAME = "infinifu-worker"
const MAX_SEQUENCE_ATTEMPTS = 64

# Root of the bus tree. Keyed entirely off XDG_RUNTIME_DIR so a test — or a
# second user on the same machine — gets a wholly separate universe.
export def bus-root []: nothing -> string {
    let base = ($env | get -o XDG_RUNTIME_DIR | default "")
    if ($base | is-empty) {
        error make {msg: "XDG_RUNTIME_DIR is unset: the worker bus has no runtime directory to address"}
    }
    $base | path join $BUS_DIRNAME
}

def run-dir [run: string]: nothing -> string { bus-root | path join $run }
def worker-dir [run: string, uid: string]: nothing -> string { run-dir $run | path join $uid }

# Refuse a bus tree we do not own or that others can read.
#
# $XDG_RUNTIME_DIR is normally private, but it is not guaranteed to be, and a
# bus tree planted under a world-writable path by someone else would otherwise
# be used as if it were ours. Envelopes carry task ids, session ids and resume
# commands; they are not for other users.
export def bus-assert-owned [dir: string] {
    if not ($dir | path exists) {
        error make {msg: $"bus directory does not exist: ($dir)"}
    }
    let owner = (^stat -c "%u" $dir | str trim | into int)
    let me = (^id -u | str trim | into int)
    if $owner != $me {
        error make {msg: $"refusing to use ($dir): owner uid ($owner) is not this user (($me))"}
    }
    let mode = (^stat -c "%a" $dir | str trim)
    if $mode != "700" {
        error make {msg: $"refusing to use ($dir): mode ($mode) is not 0700, so another user could read worker envelopes"}
    }
}

# Create a directory chain private to this user, verifying each level.
#
# `mkdir -m 700` rather than mkdir-then-chmod: the two-step version leaves the
# directory at the umask mode (0755 on a default umask) for a moment, and a
# concurrent writer that checks it in that window correctly refuses to use it.
# That is not theoretical — three racing writers hit it on the first run of the
# concurrency case. `-p` makes losing the create race a no-op instead of an
# error.
def ensure-dir [dir: string] {
    if not ($dir | path exists) {
        ^mkdir -m 700 -p $dir
    }
    bus-assert-owned $dir
}

def ensure-worker-dirs [run: string, uid: string] {
    ensure-dir (bus-root)
    ensure-dir (run-dir $run)
    ensure-dir (worker-dir $run $uid)
    for box in ["inbox" "outbox"] {
        ensure-dir (worker-dir $run $uid | path join $box)
    }
}

# Write `envelope` into `dir` at the next free sequence.
#
# The scratch file is created with the final mode BEFORE it is linked into
# place, so an envelope is never briefly readable by anyone else. link(2)
# claims the slot; if another writer got there first, the next sequence is
# tried. The scratch file is removed in both outcomes.
def claim-slot [dir: string, envelope: record] {
    let scratch = ($dir | path join $".tmp.(random chars --length 10)")

    mut seq = ((next-sequence $dir) - 1)
    mut attempts = 0
    loop {
        $seq = $seq + 1
        $attempts = $attempts + 1
        if $attempts > $MAX_SEQUENCE_ATTEMPTS {
            rm -f $scratch
            error make {msg: $"could not claim a sequence in ($dir) after ($MAX_SEQUENCE_ATTEMPTS) attempts"}
        }

        let sealed = ($envelope | update sequence $seq)
        validate-envelope $sealed
        $sealed | to json | save -f $scratch
        chmod 600 $scratch

        let target = ($dir | path join $"($seq).json")
        let linked = (do { ^ln $scratch $target } | complete)
        if $linked.exit_code == 0 {
            rm -f $scratch
            return $sealed
        }
        # Slot taken by a concurrent writer: try the next one.
    }
}

# Lowest unused sequence in a box. Sequences start at 1 so that a missing file
# and sequence zero can never be confused.
def next-sequence [dir: string]: nothing -> int {
    let used = (
        ls $dir
        | get name
        | where {|n| ($n | path basename | str ends-with ".json") }
        | each {|n| $n | path basename | str replace ".json" "" | into int }
    )
    if ($used | is-empty) { 1 } else { ($used | math max) + 1 }
}

# Read every envelope in a box, oldest first.
#
# Scratch files are skipped by name: an interrupted write leaves `.tmp.<rand>`,
# which is not a sequence file, so a partial envelope is structurally invisible
# rather than filtered out after parsing.
#
# A file that IS named like an envelope but does not parse or does not validate
# is an error, never a skip. Silently passing over it would let a completion
# disappear, which is strictly worse than stopping: the operator can fix a
# named file, but cannot notice a result that was never reported.
# NOTE ON THE LOOP: this is a `for` accumulating into a mut, not the `each`
# pipeline it visually wants to be. In nushell 0.115 an `error make` raised
# inside an `each` closure is SWALLOWED — the element is passed through and the
# pipeline completes as if nothing happened. Measured directly:
#
#   [1 2] | each {|x| if $x == 2 { error make {msg: "boom"} }; $x } | length
#   => 2      (no error surfaces)
#
# The same body inside `for` raises correctly. That difference is the whole
# reason this reads the way it does: with `each`, a corrupt envelope was
# delivered to the initiator as a bare string with no error anywhere — the
# exact silent-failure mode "fail closed" exists to prevent. Do not "simplify"
# this back into `each` without re-measuring that behavior.
def read-box [dir: string]: nothing -> list<record> {
    if not ($dir | path exists) { return [] }
    let files = (
        ls $dir
        | get name
        | where {|n| ($n | path basename | str ends-with ".json") }
        | sort-by {|n| $n | path basename | str replace ".json" "" | into int }
    )

    mut envelopes = []
    for n in $files {
        let raw = (open --raw $n)
        let parsed = (try { $raw | from json } catch {
            error make {msg: $"unparseable envelope ($n | path basename) in ($dir): the bus fails closed rather than skipping a message"}
        })
        # `from json` is lenient: given bare text it returns that text as a
        # string instead of raising, so the shape has to be checked explicitly.
        if not (($parsed | describe) | str starts-with "record") {
            error make {msg: $"unparseable envelope ($n | path basename) in ($dir): expected a JSON object, got ($parsed | describe)"}
        }
        try { validate-envelope $parsed } catch {|e|
            error make {msg: $"invalid envelope ($n | path basename) in ($dir): ($e.msg)"}
        }
        $envelopes = ($envelopes | append $parsed)
    }
    $envelopes
}

def now-stamp []: nothing -> string { date now | format date "%Y-%m-%dT%H:%M:%S%.6fZ" }

def envelope-for [run: string, uid: string, kind: string, payload: record]: nothing -> record {
    {
        protocol: $PROTOCOL_VERSION
        sequence: 0
        run: $run
        uid: $uid
        kind: $kind
        created: (now-stamp)
        payload: $payload
    }
}

# --------------------------------------------------------------- commands

# Address a message to one worker's inbox.
export def bus-send [
    uid: string
    --run: string
    --payload: record
]: nothing -> record {
    # Validate before creating anything: a rejected message must leave no trace
    # in the runtime directory, not even an empty worker tree.
    validate-envelope (envelope-for $run $uid "inbox" $payload)
    ensure-worker-dirs $run $uid
    claim-slot (worker-dir $run $uid | path join "inbox") (envelope-for $run $uid "inbox" $payload)
}

# Write a worker's outcome to its outbox.
export def bus-result [
    uid: string
    --run: string
    --result: record
]: nothing -> record {
    validate-envelope (envelope-for $run $uid "result" $result)
    ensure-worker-dirs $run $uid
    claim-slot (worker-dir $run $uid | path join "outbox") (envelope-for $run $uid "result" $result)
}

# Everything addressed to one worker.
export def bus-inbox [uid: string, --run: string]: nothing -> list<record> {
    read-box (worker-dir $run $uid | path join "inbox")
}

def ack-path [run: string, uid: string, sequence: int]: nothing -> string {
    worker-dir $run $uid | path join "outbox" $"($sequence).ack"
}

# Every unacknowledged result in a run, oldest first, across all its workers.
export def bus-pending [run: string]: nothing -> list<record> {
    let dir = (run-dir $run)
    if not ($dir | path exists) { return [] }
    let workers = (ls $dir | where type == dir | get name | sort)

    # `for`, not `each`, for the same reason as read-box: an `each` here would
    # swallow the read-box rejection it is supposed to surface.
    mut pending = []
    for w in $workers {
        let uid = ($w | path basename)
        let unacked = (
            read-box ($w | path join "outbox")
            | where {|e| not (ack-path $run $uid $e.sequence | path exists) }
        )
        $pending = ($pending | append $unacked)
    }
    $pending | sort-by created
}

# The oldest unacknowledged result in a run, or nothing.
#
# Non-destructive by design: an initiator that dies between reading this and
# acknowledging it must see the same envelope on restart. Delivery state is the
# `.ack` file on disk, never anything held in the reader.
export def bus-wait [--run: string, --json]: nothing -> any {
    let pending = (bus-pending $run)
    if ($pending | is-empty) { return null }
    let next = ($pending | first)
    if $json { $next | to json } else { $next }
}

# Record delivery of one result. This is a receipt, NOT acceptance: the work
# still needs review, and the worker stays visible until it is explicitly
# accepted.
export def bus-ack [--run: string, --uid: string, --sequence: int] {
    let envelope = (worker-dir $run $uid | path join "outbox" $"($sequence).json")
    if not ($envelope | path exists) {
        error make {msg: $"cannot acknowledge ($run)/($uid) sequence ($sequence): no such result envelope"}
    }
    let marker = (ack-path $run $uid $sequence)
    let scratch = ($marker + $".tmp.(random chars --length 10)")
    (now-stamp) | save -f $scratch
    chmod 600 $scratch
    mv -f $scratch $marker
}

# What is known about one worker.
#
# `state` is the status of its latest result. A worker with no evidence at all
# reports `unknown` — an observation, not a persisted state, and per adr0017
# never a licence to stop, accept, or delete anything.
export def bus-status [uid: string, --run: string]: nothing -> record {
    let dir = (worker-dir $run $uid)
    if not ($dir | path exists) {
        return {run: $run, uid: $uid, state: "unknown", unacked: 0, results: 0, inbox: 0}
    }
    let results = (read-box ($dir | path join "outbox"))
    let unacked = ($results | where {|e| not (ack-path $run $uid $e.sequence | path exists) })
    let state = if ($results | is-empty) { "running" } else { ($results | last | get payload.status) }
    {
        run: $run
        uid: $uid
        state: $state
        unacked: ($unacked | length)
        results: ($results | length)
        inbox: (read-box ($dir | path join "inbox") | length)
    }
}
