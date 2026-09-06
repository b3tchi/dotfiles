#!/usr/bin/env nu
# pi-worker — a message bus for visible Pi workers.
#
# Transport only. What a stage is allowed to do is declared by the consumer in
# a stage registry; see scripts/stage-registry.nu.
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
# $XDG_RUNTIME_DIR/pi-worker/<run-id>/<worker-uid>/ and nowhere else.
# The only legitimate tmux calls are window/process lifecycle: new-window,
# list-windows, kill-window.

use stage-registry.nu *

# ------------------------------------------------------------------ constants

# Bumped only for an incompatible envelope change. A reader that meets an
# unknown version fails closed rather than guessing at the fields.
export const PROTOCOL_VERSION = 1

# Envelope cap: a bus message is an address plus a pointer, never a payload of
# record. Anything approaching this size means prose is being copied that
# belongs in the consumer's own stores.
export const MAX_ENVELOPE_BYTES = 65536

# Summary cap: what the initiator reads inline. Detail stays in the visible
# worker window and the Pi JSONL.
export const MAX_SUMMARY_BYTES = 4096

export const ENVELOPE_KINDS = ["inbox" "result" "error" "identity"]

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

# A stage whose payload is "ticket" carries only an address: its message may
# name the stage and one ticket id and nothing else. The worker resolves the
# work itself from that id, so prose here would be a second source of truth
# that drifts from the first the moment either is edited.

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

# Stages the BUS itself authors, which therefore need no consumer declaration.
# `resume` sends one of these to reopen a worker, so requiring the consumer to
# register it would make the bus depend on its own caller.
const RESERVED_STAGES = ["rejection"]

# --------------------------------------------------------- payload contracts

def validate-inbox-payload [payload: record] {
    if "stage" not-in ($payload | columns) {
        error make {msg: "inbox payload must name its stage"}
    }
    let stage = $payload.stage
    let fields = ($payload | columns)

    # A bus-authored stage carries instructions by construction.
    let shape = (if $stage in $RESERVED_STAGES { "instructions" } else { stage-for $stage | get payload })
    if $shape == "ticket" {
        if "task" not-in $fields {
            error make {msg: $"payload for '($stage)' must carry its ticket id"}
        }
        let extra = ($fields | where {|f| $f not-in $WORK_PAYLOAD_ALLOWED })
        if ($extra | is-not-empty) {
            error make {msg: $"payload for '($stage)' may carry only stage and task; found ($extra | str join ', '). A ticket payload is an address, so any copied body is a second source of truth"}
        }
    } else {
        if "task" in $fields {
            error make {msg: $"payload for '($stage)' must not carry a ticket id: this stage receives direct instructions and artifact ids"}
        }
        if "instructions" not-in $fields {
            error make {msg: $"payload for '($stage)' must carry direct instructions"}
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

}

# Identity ties a worker UID to where it runs, what resumes it, and where it is
# visible. Every field is required: an identity missing its cwd or session is
# exactly the record that cannot be acted on later.
def validate-identity [payload: record] {
    for required in ["role" "cwd" "branch" "session" "skill" "window"] {
        if $required not-in ($payload | columns) {
            error make {msg: $"identity payload must carry ($required)"}
        }
        if ($payload | get $required | is-empty) {
            error make {msg: $"identity payload field '($required)' must not be empty"}
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
        "identity" => { validate-identity $envelope.payload }
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
#   $XDG_RUNTIME_DIR/pi-worker/<run-id>/<worker-uid>/
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

const BUS_DIRNAME = "pi-worker"

# The bus owns the branches it creates, so it owns their namespace. A worker
# branch is throwaway and must never collide with one a human made.
const BRANCH_PREFIX = "wk-"
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
    # The stage gate is applied here rather than at the caller, so a worker
    # cannot dodge it by taking a different code path. The stage comes from the
    # identity the orchestrator recorded at spawn; a worker with no identity
    # cannot say which stage it is, so its completion is refused outright
    # instead of being waved through ungated.
    let identity = (bus-identity-of $uid --run $run)
    if $identity == null {
        error make {msg: $"refusing a result from ($run)/($uid): no identity on the bus, so its stage gate cannot be applied"}
    }

    validate-envelope (envelope-for $run $uid "result" $result)
    ensure-worker-dirs $run $uid
    claim-slot (worker-dir $run $uid | path join "outbox") (envelope-for $run $uid "result" $result)
}

# Report that a worker's agent settled without reporting anything.
#
# dotfiles-87bt: this writer was missing, so `settled-without-result` above
# built an envelope nothing ever persisted. A worker that finished its turn
# without calling the result tool therefore produced SILENCE — state stayed
# `running`, `wait` returned nothing, and an initiator could not distinguish
# "still working" from "gave up and went quiet". The absence of a result is
# itself the report, which is the whole point of SETTLED_WITHOUT_RESULT.
#
# Reported at most once per worker, and never when a real result already
# exists: `agent_settled` fires again on every subsequent turn, and the normal
# successful path is "worker called the tool, THEN its turn settled". Emitting
# an error there would turn every healthy worker into a failed one, and
# stacking one error per settle would bury the first real outcome.
export def bus-settled [uid: string, --run: string]: nothing -> record {
    ensure-worker-dirs $run $uid
    let existing = (read-box (worker-dir $run $uid | path join "outbox"))
    if ($existing | is-not-empty) {
        return {reported: false, reason: "an outcome was already reported", run: $run, uid: $uid}
    }

    let envelope = (envelope-for $run $uid "error" {
        code: "protocol_error"
        detail: "agent settled without calling the typed result tool; completion is never inferred from an idle prompt, an exited pane, or assistant prose"
    })
    validate-envelope $envelope
    let written = (claim-slot (worker-dir $run $uid | path join "outbox") $envelope)
    {reported: true, run: $run, uid: $uid, sequence: $written.sequence}
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
    # Externally granted states win over anything the worker reported: a
    # reviewer's acceptance or an operator's teardown is later, and more
    # authoritative, than the worker's own last word about itself.
    #
    # `reopened` is the subtle one. A rejected worker's last envelope still
    # says `complete` — that report was true when it was written — so the
    # marker records WHICH result was sent back. While it covers the newest
    # result, the worker is running again; once the worker reports afresh, the
    # newer sequence outranks the marker and its real outcome shows through.
    let reopened_after = (marker-value $run $uid "reopened")
    let newest = (if ($results | is-empty) { 0 } else { $results | last | get sequence })
    let state = if (marker-path $run $uid "accepted" | path exists) {
        "accepted"
    } else if (marker-path $run $uid "stopped" | path exists) {
        "stopped"
    } else if (marker-path $run $uid "waiting_human" | path exists) {
        "waiting_human"
    } else if (($reopened_after | is-not-empty) and (($reopened_after | into int) >= $newest)) {
        "running"
    } else if ($results | is-empty) {
        "running"
    } else {
        # Dispatch on KIND, not on a field. An outbox holds `result` envelopes
        # (payload.status) and `error` envelopes (payload.code) — different
        # shapes — so reading `payload.status` off whatever came last crashed
        # with "column 'status' is missing" the first time a worker actually
        # settled without reporting. `protocol_error` was already a declared
        # WORKER_STATE; nothing had ever derived it, because dotfiles-87bt meant
        # no error envelope was ever written.
        let latest = ($results | last)
        if $latest.kind == "error" { $latest.payload.code } else { $latest.payload.status }
    }
    {
        run: $run
        uid: $uid
        state: $state
        unacked: ($unacked | length)
        results: ($results | length)
        inbox: (read-box ($dir | path join "inbox") | length)
    }
}

# ========================================================= worker worktrees
#
# Each worker gets its own git worktree at `<repo>/.worktrees/wk-<task>.<N>`
# on a branch of the same name. Directory and branch share a name so
# `git worktree list` is self-documenting and a later sweep can map a directory
# back to its task mechanically.
#
# The whole layer is biased toward refusing. Allocation must never hand back a
# worktree that already holds someone's work, and cleanup must never delete
# work that was not both committed and accepted. A false refusal costs a retry;
# a false deletion costs the work, and `git worktree remove` is the last thing
# standing between an uncommitted change and oblivion.

const WORKTREE_SUBDIR = ".worktrees"
const MAX_ITERATION_ATTEMPTS = 64

def worktrees-dir [repo: string]: nothing -> string { $repo | path join $WORKTREE_SUBDIR }

# Every branch git knows about, whether or not it has a directory.
#
# Checking directories on disk is not enough: a swept iteration leaves its
# branch behind, and handing that branch to a new worker would stack two
# attempts' history on one ref.
def known-branches [repo: string]: nothing -> list<string> {
    ^git -C $repo branch --list --format "%(refname:short)"
    | lines
    | each {|b| $b | str trim }
    | where {|b| ($b | str length) > 0 }
}

# `git worktree list --porcelain` as records of {path, branch, locked}.
def registered-worktrees [repo: string]: nothing -> list<record> {
    let out = (^git -C $repo worktree list --porcelain | lines)
    mut entries = []
    mut current = {path: "", branch: "", locked: false}
    for line in $out {
        if ($line | str starts-with "worktree ") {
            if ($current.path | is-not-empty) { $entries = ($entries | append $current) }
            $current = {path: ($line | str substring 9..), branch: "", locked: false}
        } else if ($line | str starts-with "branch ") {
            $current = ($current | update branch ($line | str substring 7.. | str replace "refs/heads/" ""))
        } else if ($line | str starts-with "locked") {
            $current = ($current | update locked true)
        }
    }
    if ($current.path | is-not-empty) { $entries = ($entries | append $current) }
    $entries
}

# True when the worktree at `path` has any change git would lose.
#
# `--porcelain` with untracked files included: an untracked scratch file is
# exactly as unrecoverable as an unstaged edit, and is the likelier of the two
# to be someone's notes.
def worktree-dirty? [path: string]: nothing -> bool {
    (^git -C $path status --porcelain --untracked-files=all | str trim | is-not-empty)
}

# Allocate the next free `wk-<task>.<N>` worktree.
#
# Serialisation reuses the bus's link(2) idiom rather than a lock file with a
# timeout: creating the branch is itself the claim. `git branch` fails if the
# ref already exists, so two racing allocators cannot both take an iteration —
# the loser sees the failure and moves to the next number. There is no window
# in which both believe they own it, and no lock to leak if a process dies.
export def worktree-allocate [--repo: string, --task: string] {
    let repo = (expand-path $repo)
    let base = (worktrees-dir $repo)
    if not ($base | path exists) { mkdir $base }

    # First of two independent guards against reusing an occupied ref. This
    # scan skips past iterations that already exist; `git worktree add -b`
    # below refuses an existing branch outright. Either alone is sufficient,
    # and they fail differently — the scan cannot see a ref created a
    # microsecond later, and the atomic create cannot tell a lost race from a
    # real error without retrying. Keeping both is deliberate, not redundant.
    # Mutating either one on its own leaves the suite green; the invariant they
    # jointly protect (an existing branch is never moved or reset) is asserted
    # directly instead.
    let taken = (known-branches $repo)
    mut n = (
        $taken
        | where {|b| $b | str starts-with $"($BRANCH_PREFIX)($task)." }
        | each {|b| try { $b | split row "." | last | into int } catch { -1 } }
        | append (-1)
        | math max
    )

    mut attempts = 0
    loop {
        $n = $n + 1
        $attempts = $attempts + 1
        if $attempts > $MAX_ITERATION_ATTEMPTS {
            error make {msg: $"could not allocate a worktree for ($task) after ($MAX_ITERATION_ATTEMPTS) attempts"}
        }

        let branch = $"($BRANCH_PREFIX)($task).($n)"
        let path = ($base | path join $branch)
        if ($path | path exists) { continue }

        # `git worktree add -b` creates the branch and the directory in one
        # step and fails if the branch already exists — that failure IS the
        # lost race, so it is a retry rather than an error.
        let added = (do { ^git -C $repo worktree add --quiet -b $branch $path } | complete)
        if $added.exit_code == 0 {
            return {branch: $branch, path: $path, iteration: $n, repo: $repo}
        }
    }
}

# Confirm a worktree is this worker's and is safe to use.
#
# Four separate refusals, because they mean different things to whoever reads
# the error: not registered (git does not know it), wrong branch (someone
# else's), locked (deliberately held), dirty (holds work).
export def worktree-validate [--repo: string, --path: string, --branch: string] {
    if not ($path | path exists) {
        error make {msg: $"worktree path does not exist: ($path)"}
    }
    let entry = (registered-worktrees $repo | where path == $path)
    if ($entry | is-empty) {
        error make {msg: $"($path) is not registered as a worktree of ($repo): git does not know about it"}
    }
    let found = ($entry | first)
    if $found.branch != $branch {
        error make {msg: $"worktree ($path) is on branch ($found.branch), not ($branch): it belongs to another worker"}
    }
    if $found.locked {
        error make {msg: $"worktree ($path) is locked: someone is deliberately holding it"}
    }
    if (worktree-dirty? $path) {
        error make {msg: $"worktree ($path) holds uncommitted work"}
    }
}

# Remove a worker's worktree and branch — only with evidence that the work is
# finished with.
#
# Two independent gates, and both must pass:
#
#   1. Evidence. Either an explicit `--accepted` (a human or a reviewer said
#      so) or `--merged-into <base>`, which is VERIFIED against git rather than
#      believed: the branch must actually be an ancestor of that base. A caller
#      that merges, fails, and cleans up anyway would otherwise delete the only
#      copy of the work.
#   2. Cleanliness. Uncommitted or untracked files block removal regardless of
#      evidence. Acceptance is a statement about the reported result, not about
#      whatever is sitting unstaged in the directory.
#
# `git worktree remove` and `git branch -d` are both used WITHOUT their force
# flags on purpose: they are the last safety net, and a refusal here is
# information, not an obstacle to route around.
export def worktree-cleanup [
    --repo: string
    --path: string
    --branch: string
    --accepted
    --merged-into: string = ""
] {
    let repo = (expand-path $repo)
    let path = (expand-path $path)
    if not $accepted and ($merged_into | is-empty) {
        error make {msg: $"refusing to clean up ($path): no acceptance or merge evidence. A completed worker stays visible until something explicitly says the work is done with"}
    }

    if ($merged_into | is-not-empty) {
        let merged = (do { ^git -C $repo merge-base --is-ancestor $branch $merged_into } | complete)
        if $merged.exit_code != 0 {
            error make {msg: $"refusing to clean up ($branch): it is not merged into ($merged_into). The merge claim is verified against git, not taken on the caller's word"}
        }
    }

    # The main worktree is never a worker's to delete. A stage declared
    # (dotfiles-ptba), so `worker-accept` reaches here with identity.cwd set to
    # it. git refuses on its own — but only after the accept sequence has
    # already killed the window, and with a message about working trees rather
    # than about what the caller did wrong.
    if $path == (main-worktree $repo) {
        error make {msg: $"refusing to clean up ($path): that is the main worktree, not a worker's. A stage declared isolation=main runs there and shares it with the operator; only its own isolated worktree is a worker's to remove"}
    }

    if ($path | path exists) and (worktree-dirty? $path) {
        error make {msg: $"refusing to clean up ($path): it holds uncommitted work, which acceptance does not license deleting"}
    }

    if ($path | path exists) {
        let removed = (do { ^git -C $repo worktree remove $path } | complete)
        if $removed.exit_code != 0 {
            error make {msg: $"could not remove worktree ($path): ($removed.stderr | str trim)"}
        }
    }

    let deleted = (do { ^git -C $repo branch -d $branch } | complete)
    if $deleted.exit_code != 0 {
        error make {msg: $"worktree ($path) removed, but branch ($branch) was not deleted: ($deleted.stderr | str trim). Bus metadata is intact; finish by hand"}
    }
}

# --------------------------------------------------------------- identity
#
# The identity envelope is what ties a worker UID to the worktree it runs in,
# the Pi session that can resume it, and the tmux window that displays it. It
# lives on the bus, NOT inside the worktree, so it outlives cleanup: an
# accepted worker whose directory is gone must still be resumable from its
# session id.

export def bus-identity [uid: string, --run: string, --identity: record]: nothing -> record {
    validate-identity $identity
    ensure-worker-dirs $run $uid
    ensure-dir (worker-dir $run $uid | path join "identity")
    claim-slot (worker-dir $run $uid | path join "identity") (envelope-for $run $uid "identity" $identity)
}

# The worker's current identity, or nothing if it was never recorded.
export def bus-identity-of [uid: string, --run: string]: nothing -> any {
    let dir = (worker-dir $run $uid | path join "identity")
    let records = (read-box $dir)
    if ($records | is-empty) { return null }
    $records | last | get payload
}

# ====================================================== visible Pi workers
#
# A worker is a Pi process in a named tmux window inside the existing linked
# project group. tmux's ONLY jobs here are to display the process and to keep
# it alive; see the transport-boundary note at the top of this file. Spawning
# uses `new-window` and liveness uses `list-windows` — no send-keys, no
# wait-for, no pane options.


# Expand a path argument before anything is done with it.
#
# An agent driving this tool writes `~/.dotfiles`, because that is how a human
# writes it. Nothing on the way to git expands a tilde, so it used to arrive
# literally and fail with "cannot change to '~/.dotfiles'" — a confusing error
# for an argument that looks correct. Expanding once, at the edge, keeps every
# interior path absolute.
export def expand-path [path: string]: nothing -> string {
    if ($path | is-empty) { $path } else { $path | path expand }
}

# The main worktree of a repo — the one git lists first, and where a stage
# declared isolation=main runs.
export def main-worktree [repo_in: string]: nothing -> string {
    let repo = (expand-path $repo_in)
    let listed = (do { ^git -C $repo worktree list --porcelain } | complete)
    if $listed.exit_code != 0 {
        error make {msg: $"cannot list worktrees for ($repo): ($listed.stderr | str trim)"}
    }
    let first = (
        $listed.stdout
        | lines
        | where {|l| $l | str starts-with "worktree " }
        | first
    )
    $first | str replace "worktree " "" | str trim
}

# Where a worker runs, and on which branch.
#
# Declared per stage in the registry, because only the consumer knows which of
# its stages can tolerate an isolated checkout:
#
#   isolation=worktree  its own throwaway `wk-<subject>.<N>` worktree and
#                       branch, so concurrent workers never share a tree
#   isolation=main      the repo's main worktree on the default branch, and no
#                       task branch — for stages whose tooling refuses to run
#                       anywhere else, or whose writes belong on the canonical
#                       branch
#
# `main` means the worker shares a tree with the operator and with every other
# such worker, so a consumer that declares it owns the serialisation problem.
export def worker-placement [
    --repo: string
    --skill: string
    --subject: string
]: nothing -> record {
    let repo = (expand-path $repo)
    if (stage-for $skill | get isolation) == "main" {
        let main = (main-worktree $repo)
        let branch = (^git -C $main rev-parse --abbrev-ref HEAD | str trim)
        return {path: $main, branch: $branch, isolated: false}
    }

    let tree = (worktree-allocate --repo $repo --task $subject)
    {path: $tree.path, branch: $tree.branch, isolated: true}
}

# The tmux session to create a worker's window in, given a project name.
#
# dotfiles-k5vt: `--project` is documented as a session GROUP, and that is the
# right model — grouped sessions share windows, so a worker window created in
# any member appears in all of them, and `<role>-<subject>@<group>` is what an
# operator scans a window list for. But `tmux -t` neither resolves groups nor
# matches them: it PREFIX-matches session names. So `-t dotfiles` against a
# group holding `dotfiles_7` alone matches by accident and looks correct, while
# the same command against `dotfiles_3 .. dotfiles_36` is ambiguous and fails
# with "can't find window: dotfiles" — which is what the live run hit.
#
# Accidental prefix uniqueness is worse than an outright failure: it works
# until the operator opens a second view. So the group is resolved explicitly.
#
# An exact session name wins over a group of the same name: it is unambiguous,
# and it is what an operator reaches for to pin one view out of many.
export def resolve-project-session [project: string, --socket: string = ""] {
    let listed = (do { ^tmux ...(tmux-args $socket) list-sessions -F "#{session_name}\t#{session_group}" } | complete)
    if $listed.exit_code != 0 {
        error make {msg: $"cannot list tmux sessions: ($listed.stderr | str trim)"}
    }

    let sessions = (
        $listed.stdout
        | lines
        | each {|l| $l | split row "\t" }
        | where {|r| ($r | length) >= 1 and (($r | first | str trim) | is-not-empty) }
        | each {|r| {name: ($r | first | str trim), group: (if ($r | length) >= 2 { $r | get 1 | str trim } else { "" })} }
    )

    let exact = ($sessions | where name == $project)
    if ($exact | is-not-empty) { return ($exact | first | get name) }

    # Any member will do — grouped sessions share their window list, so the
    # window appears in every view either way. Sorted for determinism: the same
    # project must resolve to the same session across calls.
    let members = ($sessions | where group == $project | sort-by name)
    if ($members | is-not-empty) { return ($members | first | get name) }

    error make {msg: $"no tmux session or session group named '($project)'. Known sessions: ($sessions | get name | sort | str join ', ')"}
}

# The name an operator scans a window list for: `<role>-<subject>@<project>`.
# Subject is the ticket id for ticket-payload stages and the artifact id otherwise.
export def worker-window-name [role: string, subject: string, project: string]: nothing -> string {
    $"($role)-($subject)@($project)"
}

def tmux-args [socket: string]: nothing -> list<string> {
    if ($socket | is-empty) { [] } else { ["-L" $socket] }
}

# What can be observed about a worker's process, as one of three verdicts.
#
# dotfiles-yii5: this probe used to match on the window NAME alone and return a
# bool. But spawn sets `remain-on-exit on` deliberately — a crashed worker's
# window stays listed so its error stays on screen — so a worker whose process
# died at startup still had its name in the list, and the tool reported it
# healthy. Every worker was dead for the whole of the dotfiles-4xtz bug while
# `live: true` came back each time.
#
# adr0017 dictates the shape. "I cannot tell" is a first-class verdict, distinct
# from "it is dead", and absence of evidence must never be encoded as evidence
# of absence. A bool cannot carry both, so:
#
#   live     the pane exists and its process is running
#   exited   the pane exists and its process is gone — the worker's OWN
#            evidence about ITSELF, and therefore reportable
#   unknown  no such window, or tmux could not be reached — nobody watched, so
#            nothing was observed
#
# `unknown` is an OBSERVATIONAL verdict: never persisted, never a licence to
# stop, accept, or delete anything. Neither is `exited` — knowing a process
# stopped is not knowing the work is finished.
export def worker-liveness [window: string, --socket: string = ""]: nothing -> record {
    let listed = (do { ^tmux ...(tmux-args $socket) list-panes -a -F "#{window_name}\t#{pane_dead}" } | complete)
    # A caller that could not reach tmux has learned nothing about the worker.
    # Reporting "exited" here would be the caller's failure misattributed to the
    # component — the exact confusion adr0017 forbids.
    if $listed.exit_code != 0 {
        return {verdict: "unknown", window: $window, reason: "tmux could not be reached"}
    }

    let panes = (
        $listed.stdout
        | lines
        | each {|l| $l | split row "\t" }
        | where {|p| ($p | length) >= 2 and (($p | first | str trim) == $window) }
    )
    if ($panes | is-empty) {
        return {verdict: "unknown", window: $window, reason: "no window by that name"}
    }

    # Grouped sessions list the same window once per session, so a window may
    # appear several times. Any live pane means the worker is running.
    let any_alive = ($panes | any {|p| ($p | get 1 | str trim) != "1" })
    if $any_alive {
        {verdict: "live", window: $window, reason: "its process is running"}
    } else {
        {verdict: "exited", window: $window, reason: "the window remains but its process is gone"}
    }
}

# Whether a worker is OBSERVABLY RUNNING.
#
# Strictly `verdict == "live"`. Both other verdicts are false, and callers must
# not read that false as permission to clean anything up: "exited" and "unknown"
# mean different things, and only `worker-liveness` can tell them apart.
export def worker-live? [window: string, --socket: string = ""]: nothing -> bool {
    (worker-liveness $window --socket $socket | get verdict) == "live"
}

# Start a visible, resumable Pi worker.
#
# Order matters. The worktree is allocated and the identity envelope is written
# BEFORE the process starts, so a worker that dies during startup still leaves
# a resume command and a cwd behind. Evidence first, process second: the
# reverse order loses exactly the information needed to diagnose a failed
# start.
export def worker-spawn [
    --run: string
    --uid: string
    --role: string
    --subject: string
    --project: string
    --repo: string
    --task: string = ""
    --session: string
    --skill: string
    --socket: string = ""
] {
    let stage = (stage-for $skill)
    if ($stage.payload == "ticket") and ($task | is-empty) {
        error make {msg: $"stage '($skill)' takes a ticket payload and so needs a ticket id; the worker resolves the work from it"}
    }

    # Fail before allocating anything if the display host is unreachable.
    let reachable = (do { ^tmux ...(tmux-args $socket) list-sessions } | complete)
    if $reachable.exit_code != 0 {
        let which = (if ($socket | is-empty) { "default" } else { $socket })
        error make {msg: $"cannot reach tmux server \(socket: ($which)): ($reachable.stderr | str trim)"}
    }

    # Resolved BEFORE anything is allocated. A wrong --project used to fail at
    # new-window, after the worktree and identity envelope had been written,
    # leaving a branch to prune by hand (hit on the first live run).
    let target = (resolve-project-session $project --socket $socket)

    let window = (worker-window-name $role $subject $project)
    # NOT `$task | default $subject`. `default` substitutes for null, not for an
    # empty string, so a stage with no task would have allocated a worktree
    # named `wk-.0`; worse, nushell raises on `default` applied to a plain string
    # and reports it as the entirely unrelated "External command failed", which
    # is how this sat hidden behind a passing-looking spawn.
    let subject_for_branch = (if ($task | is-empty) { $subject } else { $task })
    # Placement is stage-dependent; the registry says which (dotfiles-ptba).
    let tree = (worker-placement --repo $repo --skill $skill --subject $subject_for_branch)

    bus-identity $uid --run $run --identity {
        role: $role
        cwd: $tree.path
        branch: $tree.branch
        session: $session
        skill: $skill
        window: $window
    }

    # `--session-id`, NOT `--session`. Pi's two session flags are not aliases:
    # `--session <path|id>` RESUMES an existing session and exits with "No
    # session found matching '<id>'" when it is absent, while `--session-id`
    # uses that exact id and creates it if missing. spawn mints a fresh uuid,
    # so the session cannot exist yet and the resuming flag is always wrong
    # here. A live run against Pi 0.84.4 hit exactly that: the pane died at
    # startup while spawn still reported live: true. The resume hint below is
    # the opposite case -- by then the session exists, so plain `--session` is
    # correct there.
    #
    # `remain-on-exit on` keeps a crashed or finished worker's window in place.
    # Without it a Pi that fails during startup takes its own error message off
    # the screen, and the operator is left with a missing window and no reason.
    # The worker's identity reaches the extension as environment, not as a
    # message: the extension needs to know which inbox is its own BEFORE any
    # message can be delivered, and a bootstrap message would have nowhere to
    # arrive. `new-window -e` sets these on the window's own environment only,
    # so nothing leaks into the operator's other windows.
    let worker_env = [
        "-e" $"PI_WORKER_RUN=($run)"
        "-e" $"PI_WORKER_UID=($uid)"
        "-e" $"PI_WORKER_ROLE=($role)"
        "-e" $"PI_WORKER_BRANCH=($tree.branch)"
        "-e" $"PI_WORKER_SESSION=($session)"
        "-e" $"PI_WORKER_SKILL=($skill)"
        "-e" $"PI_WORKER_WINDOW=($window)"
    ]
    let created = (do {
        ^tmux ...(tmux-args $socket) new-window -d -t $target -n $window -c $tree.path ...$worker_env "pi" "--session-id" $session
    } | complete)
    if $created.exit_code != 0 {
        error make {msg: $"tmux could not create window ($window): ($created.stderr | str trim)"}
    }
    do { ^tmux ...(tmux-args $socket) set-option -t $window remain-on-exit on } | complete | ignore

    {
        run: $run
        uid: $uid
        role: $role
        window: $window
        cwd: $tree.path
        branch: $tree.branch
        session: $session
        skill: $skill
        resume: $"pi --session ($session)"
        # Both, because they answer different questions. `live` is the bool an
        # operator skims; `liveness` is the verdict adr0017 requires when the
        # answer might be "I cannot tell" — see worker-liveness. Note this is a
        # snapshot taken moments after new-window, so a process that dies during
        # startup may still read `live` here; a later probe is what tells the
        # truth, which is why nothing downstream trusts this field.
        live: (worker-live? $window --socket $socket)
        liveness: (worker-liveness $window --socket $socket | get verdict)
    }
}

# ==================================================== stage completion gates
#
# A stage may report `complete` only when it carries the verdict its own
# discipline produces. The verdict is read from the typed `validation` field
# and NEVER from the summary: an assistant writing its verdict in prose is the
# exact forgery this design exists to refuse, and text is the one thing a
# model can always produce.
#
# spec-refinement is called out by name because its verdict is a specific
# token its own skill defines. Every other stage needs a non-empty verdict —
# whatever evidence that stage actually produces — because "complete with no
# verdict" is how an unvalidated result reaches the pipeline.



# ================================================== orchestration verbs (T5)
#
# The scrum-master's Pi branch drives the pipeline through these and nothing
# else. Each one is a state transition validated against the T1 table before
# anything is touched, so an illegal move is refused rather than half-applied.
#
# Two markers carry the states no result envelope can express, because they are
# granted from outside the worker: `accepted` (a reviewer or a successful merge
# said the work is done with) and `stopped` (someone tore it down). They live
# beside the worker's envelopes, so a restarted initiator reads them the same
# way it reads everything else.

def marker-path [run: string, uid: string, name: string]: nothing -> string {
    worker-dir $run $uid | path join $"($name).marker"
}

def write-marker [run: string, uid: string, name: string, value: string = ""] {
    let marker = (marker-path $run $uid $name)
    let scratch = ($marker + $".tmp.(random chars --length 10)")
    (if ($value | is-empty) { now-stamp } else { $value }) | save -f $scratch
    chmod 600 $scratch
    mv -f $scratch $marker
}

def marker-value [run: string, uid: string, name: string]: nothing -> string {
    let marker = (marker-path $run $uid $name)
    if not ($marker | path exists) { return "" }
    open --raw $marker | str trim
}

def marker-set? [run: string, uid: string, name: string]: nothing -> bool {
    marker-path $run $uid $name | path exists
}

# Count how many times this worker has been sent back. Rejections are derived
# from the messages actually on the bus rather than tracked in the
# orchestrator, so the count survives a restart.
def rejection-count [run: string, uid: string]: nothing -> int {
    bus-inbox $uid --run $run
    | where {|e| ($e.payload | get -o stage) == "rejection" }
    | length
}

# Everything known about one worker, without consuming anything.
export def worker-inspect [uid: string, --run: string, --sessions-dir: string = ""]: nothing -> record {
    let identity = (bus-identity-of $uid --run $run)
    if $identity == null {
        error make {msg: $"unknown worker ($run)/($uid): no identity on the bus. Absent evidence is not permission to act \(adr0017)"}
    }
    let results = (read-box (worker-dir $run $uid | path join "outbox"))
    {
        run: $run
        uid: $uid
        identity: $identity
        state: (bus-status $uid --run $run | get state)
        last_result: (if ($results | is-empty) { null } else { $results | last | get payload })
        rejections: (rejection-count $run $uid)
        resume: (resume-hint $identity --sessions-dir $sessions_dir)
        transcript: (pi-session-file $identity.session --sessions-dir $sessions_dir)
    }
}

# Where Pi stores a session's transcript, or null when it cannot be found.
#
# Pi files sessions under one directory per project slug, named
# `<timestamp>_<uuid>.jsonl`. The timestamp is Pi's to choose, so the path
# cannot be predicted at spawn — it is located by id when someone asks.
#
# Returns null rather than a constructed path: sending an operator to a file
# that is not there is worse than telling them it is missing.
export def pi-session-file [session: string, --sessions-dir: string = ""]: nothing -> any {
    let base = (if ($sessions_dir | is-empty) {
        $env.HOME? | default "" | path join ".pi" "agent" "sessions"
    } else { $sessions_dir })
    if not ($base | path exists) { return null }

    let hits = (
        do { ^find $base -type f -name $"*_($session).jsonl" } | complete
        | if $in.exit_code == 0 { $in.stdout | lines } else { [] }
        | where {|l| ($l | str trim | is-not-empty) }
        | sort
    )
    if ($hits | is-empty) { null } else { $hits | first | str trim }
}

# How to get back into a worker's conversation, answered for the world as it is
# right now.
#
# dotfiles-lr2w: every result envelope carries `pi --session <id>`, and the T7
# checklist promised that command still works after `accept`. It does not. Pi
# binds a session to the directory it was created in and refuses to start once
# that directory is gone:
#
#   Stored session working directory does not exist: .../wk-t1.0
#
# Naming the session file instead of the id does not help — same refusal. The
# transcript survives, so nothing is lost, but the documented command cannot
# reach it. `pi --fork <file>` can, from any valid directory, which is the
# honest answer once a work stage's worktree has been reclaimed.
#
# Derived, never stored: the truth changes when the worktree is removed, and a
# recorded string would go stale at exactly that moment.
export def resume-hint [identity: record, --sessions-dir: string = ""]: nothing -> string {
    if ($identity.cwd | path exists) {
        return $"pi --session ($identity.session)"
    }
    let transcript = (pi-session-file $identity.session --sessions-dir $sessions_dir)
    if $transcript == null {
        return $"cannot resume: the worker's directory ($identity.cwd) no longer exists and no transcript for session ($identity.session) was found"
    }
    $"pi --fork ($transcript)"
}

# Every worker in a run, reconstructed from the bus alone.
#
# This is what makes an initiator restartable: no part of a run's shape lives
# in the orchestrator's memory, so a fresh process can list the workers, their
# states, their undelivered results and their resume commands.
export def run-workers [run: string]: nothing -> list<record> {
    let dir = (bus-root | path join $run)
    if not ($dir | path exists) { return [] }
    ls $dir | where type == dir | get name | sort | each {|w|
        let uid = ($w | path basename)
        let status = (bus-status $uid --run $run)
        let identity = (bus-identity-of $uid --run $run)
        {
            run: $run
            uid: $uid
            state: $status.state
            unacked: $status.unacked
            window: (if $identity == null { "" } else { $identity.window })
            resume: (if $identity == null { "" } else { $"pi --session ($identity.session)" })
        }
    }
}

# Send a worker back with reviewer feedback, resuming its ORIGINAL session.
#
# Resuming rather than dispatching fresh is the point of a stable session id:
# the worker still has its context and its worktree, so the second attempt
# starts from the first rather than from nothing. The feedback travels as an
# instruction-shaped message — it is prose, and a ticket payload carries only an id
# id.
#
# A second rejection sets `escalate` and parks the worker at `waiting_human`.
# A third silent retry would burn another model turn on the same
# misunderstanding; at that point a person needs to look.
export def worker-resume [
    uid: string
    --run: string
    --feedback: string
    --socket: string = ""
]: nothing -> record {
    let seen = (worker-inspect $uid --run $run)
    let rejections = ($seen.rejections + 1)

    bus-send $uid --run $run --payload {
        stage: "rejection"
        instructions: $feedback
        artifacts: []
    }

    # Reopening is always the first move: `complete -> running` is a legal edge
    # precisely so a rejected result can be sent back without inventing a new
    # worker. Escalation is then a SECOND legal step, `running -> waiting_human`
    # — walking the table rather than adding a `complete -> waiting_human` edge
    # that would let a worker be parked without ever being reopened.
    validate-transition $seen.state "running"
    rm -f (marker-path $run $uid "waiting_human")
    let newest = (
        read-box (worker-dir $run $uid | path join "outbox")
        | each {|e| $e.sequence }
        | append 0
        | math max
    )
    write-marker $run $uid "reopened" ($newest | into string)

    if $rejections >= 2 {
        validate-transition "running" "waiting_human"
        write-marker $run $uid "waiting_human"
    }

    {
        run: $run
        uid: $uid
        session: $seen.identity.session
        window: $seen.identity.window
        rejections: $rejections
        escalate: ($rejections >= 2)
        state: (bus-status $uid --run $run | get state)
    }
}

# Accept a completed worker: close its window and clean its worktree.
#
# The gates are deliberately stacked. Only a `complete` worker may be accepted
# (the T1 table's single edge into `accepted`), the worktree must hold no
# uncommitted work, and both the window and the worktree are addressed through
# this run's own identity record — so an acceptance can only ever reach the
# worker it names, never another run's.
export def worker-accept [
    uid: string
    --run: string
    --repo: string
    --socket: string = ""
] {
    let seen = (worker-inspect $uid --run $run)
    validate-transition $seen.state "accepted"

    # The window closes first: it is recoverable (spawn again from the session
    # id), whereas the worktree is not, so the irreversible step goes last.
    do { ^tmux ...(tmux-args $socket) kill-window -t $seen.identity.window } | complete | ignore

    # An isolation=main stage runs IN the main worktree, shared with the operator
    # and is nobody's to delete. There is no isolated directory or task branch
    # to reclaim, so acceptance is the marker alone.
    if $seen.identity.cwd != (main-worktree $repo) {
        worktree-cleanup --repo $repo --path $seen.identity.cwd --branch $seen.identity.branch --accepted
    }
    write-marker $run $uid "accepted"
}

# Tear a worker down without accepting its work.
#
# Stopping closes the window and nothing else. The worktree may hold unmerged
# commits, so it stays until something explicitly says the work is finished
# with — `stopped` is terminal, and a stopped worker can never become
# `accepted`.
export def worker-stop [uid: string, --run: string, --socket: string = ""] {
    let seen = (worker-inspect $uid --run $run)
    validate-transition $seen.state "stopped"
    do { ^tmux ...(tmux-args $socket) kill-window -t $seen.identity.window } | complete | ignore
    write-marker $run $uid "stopped"
}

# Every result a worker has reported, oldest first. Envelopes are append-only,
# so a later completion does not erase an earlier failure — the history stays
# auditable rather than being overwritten by the latest word.
export def read-results [uid: string, --run: string]: nothing -> list<record> {
    read-box (worker-dir $run $uid | path join "outbox") | each {|e| $e.payload }
}

# Record acceptance without touching tmux or git. worker-accept is the verb an
# orchestrator uses; this is the state half on its own, for callers that have
# already done the cleanup (and for tests that need the state without a repo).
export def mark-accepted [uid: string, --run: string] {
    let state = (bus-status $uid --run $run | get state)
    validate-transition $state "accepted"
    write-marker $run $uid "accepted"
}

# ============================================================== CLI entry point
#
# The installer links this file into ~/.local/bin/pi-worker, so it has to
# work as a command and not only as an imported module. Every verb below is a
# thin wrapper over the exported function of the same name: the CLI is a
# surface, never a second implementation that could drift from the one the
# tests drive.
#
# Output is JSON, because every consumer is another program — the scrum-master
# skill, a shell conditional, or a test.

def usage []: nothing -> string {
    [
        "pi-worker — visible Pi worker orchestration (ft014)"
        ""
        "USAGE"
        "  pi-worker <verb> [flags]"
        ""
        "VERBS"
        "  spawn    --run --uid --role --subject --project --repo --session --skill [--task] [--socket]"
        "  send     <uid> --run --stage [--task | --instructions] [--artifacts]"
        "  result   <uid> --run --status --summary [--validation]   report an outcome"
        "  settled  <uid> --run                 report settling with nothing to show"
        "  wait     --run                       oldest unacknowledged result, or nothing"
        "  ack      --run --uid --sequence      delivery receipt; NOT acceptance"
        "  status   <uid> --run                 one worker's state, from the bus"
        "  liveness <uid> --run [--socket]      live | exited | unknown, from tmux"
        "  inspect  <uid> --run                 identity, last result, resume command"
        "  workers  --run                       every worker in a run, from the bus alone"
        "  resume   <uid> --run --feedback      send back to the ORIGINAL session"
        "  accept   <uid> --run --repo          close the window, remove the worktree"
        "  stop     <uid> --run                 close the window, KEEP the worktree"
        "  doctor                               check dependencies"
        ""
        "NOTES"
        "  wait is non-destructive: it redelivers until ack, so an initiator that"
        "  dies mid-handling sees the result again. ack confirms delivery only —"
        "  a completed worker stays visible until accept."
    ] | str join "\n"
}

# The rest parameter exists so an unrecognised verb produces a useful message.
# Without it nushell reports "Extra positional argument", which names neither
# what was asked for nor what is available — the two things the operator needs.
def main [...args: string] {
    if ($args | is-empty) {
        print (usage)
        return
    }
    print --stderr $"pi-worker: unknown verb '($args | first)'"
    print --stderr ""
    print --stderr (usage)
    exit 2
}

def "main spawn" [
    --run: string, --uid: string, --role: string, --subject: string
    --project: string, --repo: string, --session: string, --skill: string
    --task: string = "", --socket: string = ""
] {
    worker-spawn --run $run --uid $uid --role $role --subject $subject --project $project --repo $repo --task $task --session $session --skill $skill --socket $socket
    | to json
    | print
}

def "main send" [
    uid: string, --run: string, --stage: string
    --task: string = "", --instructions: string = "", --artifacts: string = ""
] {
    let payload = if ($task | is-empty) {
        {stage: $stage, instructions: $instructions, artifacts: ($artifacts | split row "," | where {|a| ($a | str trim | is-not-empty) })}
    } else {
        {stage: $stage, task: $task}
    }
    bus-send $uid --run $run --payload $payload | to json | print
}

# Prints nothing when there is no mail, so `if (pi-worker wait --run r |
# is-empty)` works in a script. Silence is the answer, not an error.
def "main wait" [--run: string] {
    let next = (bus-wait --run $run)
    if $next != null { print ($next | to json) }
}

def "main ack" [--run: string, --uid: string, --sequence: int] {
    bus-ack --run $run --uid $uid --sequence $sequence
}

# The worker's own side of the bus (dotfiles-87bt).
#
# `bus-result` and the settle reporter had no CLI surface, and the extension
# registered no tool, so a worker had no way to report an outcome by ANY route
# while work-do/SKILL.md instructed it to "finish by calling the typed result
# tool". These two verbs are that path. The extension's typed tool is a thin
# wrapper over `result`, so the envelope shape and the stage gate have exactly
# one implementation instead of one per runtime.
def "main result" [
    uid: string, --run: string, --status: string, --summary: string
    --validation: string = ""
] {
    # The worker supplies its OUTCOME; window, session and resume come from the
    # identity the orchestrator recorded at spawn. A worker cannot be trusted to
    # say where it lives or how to reach it — that is the initiator's only route
    # back to it, and a worker that could rewrite it could point the initiator
    # at someone else's session.
    let identity = (bus-identity-of $uid --run $run)
    if $identity == null {
        error make {msg: $"refusing a result from ($run)/($uid): no identity on the bus, so there is nothing to report against"}
    }

    let base = {
        status: $status
        summary: $summary
        window: $identity.window
        session: $identity.session
        resume: $"pi --session ($identity.session)"
    }
    # An absent verdict must stay ABSENT rather than become "": the gate reads
    # emptiness, and a present-but-empty field is the shape a caller uses to
    # look compliant without having validated anything.
    let payload = (if ($validation | is-empty) { $base } else { $base | merge {validation: $validation} })
    bus-result $uid --run $run --result $payload | to json | print
}

def "main settled" [uid: string, --run: string] {
    bus-settled $uid --run $run | to json | print
}

# The tmux-side probe, kept OFF `inspect` and `status` on purpose: those two
# rebuild a run from the bus alone, without tmux, which is what lets a restarted
# initiator recover. This verb is the one that needs a display host, so it is
# the one that carries the --socket.
def "main liveness" [uid: string, --run: string, --socket: string = ""] {
    let identity = (bus-identity-of $uid --run $run)
    if $identity == null {
        error make {msg: $"unknown worker ($run)/($uid): no identity on the bus. Absent evidence is not permission to act \(adr0017)"}
    }
    worker-liveness $identity.window --socket $socket | to json | print
}

def "main status" [uid: string, --run: string] { bus-status $uid --run $run | to json | print }
def "main inspect" [uid: string, --run: string] { worker-inspect $uid --run $run | to json | print }
def "main workers" [--run: string] { run-workers $run | to json | print }

def "main resume" [uid: string, --run: string, --feedback: string, --socket: string = ""] {
    worker-resume $uid --run $run --feedback $feedback --socket $socket | to json | print
}

def "main accept" [uid: string, --run: string, --repo: string, --socket: string = ""] {
    worker-accept $uid --run $run --repo $repo --socket $socket
}

def "main stop" [uid: string, --run: string, --socket: string = ""] {
    worker-stop $uid --run $run --socket $socket
}

# Report on each dependency SEPARATELY. A single "something is missing" tells
# an operator nothing they can act on; naming the one that is absent turns a
# support question into a one-line fix.
def "main doctor" [] {
    let checks = [
        {
            name: "nushell"
            ok: true
            detail: $"($nu.current-exe) (version | get version)"
        }
        {
            name: "tmux"
            ok: ((do { ^tmux -V } | complete | get exit_code) == 0)
            detail: (do { ^tmux -V } | complete | get stdout | str trim)
        }
        {
            name: "XDG_RUNTIME_DIR"
            ok: (($env | get -o XDG_RUNTIME_DIR | default "" | is-not-empty))
            detail: ($env | get -o XDG_RUNTIME_DIR | default "unset — export it, e.g. /run/user/$(id -u)")
        }
        {
            name: "pi"
            ok: ((do { ^pi --version } | complete | get exit_code) == 0)
            detail: (do { ^pi --version } | complete | get stdout | str trim)
        }
    ]
    for c in $checks {
        let mark = (if $c.ok { "ok  " } else { "MISS" })
        print $"($mark) ($c.name): ($c.detail)"
    }
    if ($checks | where {|c| not $c.ok and $c.name != "pi" } | is-not-empty) {
        # `pi` absent is fine on a Claude-only box; the rest are not.
        error make {msg: "required dependencies are missing (see MISS lines above)"}
    }
}
