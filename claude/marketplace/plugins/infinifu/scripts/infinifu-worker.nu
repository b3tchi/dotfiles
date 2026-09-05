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
        $results | last | get payload.status
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
# Each worker gets its own git worktree at `<repo>/.worktrees/bd-<task>.<N>`
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

# Allocate the next free `bd-<task>.<N>` worktree.
#
# Serialisation reuses the bus's link(2) idiom rather than a lock file with a
# timeout: creating the branch is itself the claim. `git branch` fails if the
# ref already exists, so two racing allocators cannot both take an iteration —
# the loser sees the failure and moves to the next number. There is no window
# in which both believe they own it, and no lock to leak if a process dies.
export def worktree-allocate [--repo: string, --task: string] {
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
        | where {|b| $b | str starts-with $"bd-($task)." }
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

        let branch = $"bd-($task).($n)"
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
    if not $accepted and ($merged_into | is-empty) {
        error make {msg: $"refusing to clean up ($path): no acceptance or merge evidence. A completed worker stays visible until something explicitly says the work is done with"}
    }

    if ($merged_into | is-not-empty) {
        let merged = (do { ^git -C $repo merge-base --is-ancestor $branch $merged_into } | complete)
        if $merged.exit_code != 0 {
            error make {msg: $"refusing to clean up ($branch): it is not merged into ($merged_into). The merge claim is verified against git, not taken on the caller's word"}
        }
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

# Skills a worker may be configured with, and whether the stage takes a bd task
# contract. An unrecognised skill is refused rather than launched: a worker with
# no contract to follow would burn a model turn and report nothing useful.
const WORKER_SKILLS = [
    [skill, kind];
    ["work-do", "work"]
    ["work-audit", "work"]
    ["work-merge", "work"]
    ["spec-writing", "akm"]
    ["spec-refinement", "akm"]
    ["spec-ready", "akm"]
    ["spec-retro", "akm"]
]

# The name an operator scans a window list for: `<role>-<subject>@<project>`.
# Subject is the bd task id for work stages and the artifact id otherwise.
export def worker-window-name [role: string, subject: string, project: string]: nothing -> string {
    $"($role)-($subject)@($project)"
}

def tmux-args [socket: string]: nothing -> list<string> {
    if ($socket | is-empty) { [] } else { ["-L" $socket] }
}

# Whether a window with this name currently exists.
#
# Reports what was observed and nothing more: a missing window means "not
# found", which per adr0017 is a fact to act on carefully, never a licence to
# clean up the worker's worktree or evidence.
export def worker-live? [window: string, --socket: string = ""]: nothing -> bool {
    let listed = (do { ^tmux ...(tmux-args $socket) list-windows -a -F "#{window_name}" } | complete)
    if $listed.exit_code != 0 { return false }
    $window in ($listed.stdout | lines | each {|w| $w | str trim })
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
    let configured = ($WORKER_SKILLS | where skill == $skill)
    if ($configured | is-empty) {
        error make {msg: $"unknown skill '($skill)': not one of ($WORKER_SKILLS | get skill | str join ', '). A worker with no contract to follow is not launched"}
    }
    if (($configured | first | get kind) == "work") and ($task | is-empty) {
        error make {msg: $"skill '($skill)' is a work stage and needs a bd task id: the worker reads its contract with `bd show <id>`"}
    }

    # Fail before allocating anything if the display host is unreachable.
    let reachable = (do { ^tmux ...(tmux-args $socket) list-sessions } | complete)
    if $reachable.exit_code != 0 {
        let which = (if ($socket | is-empty) { "default" } else { $socket })
        error make {msg: $"cannot reach tmux server \(socket: ($which)): ($reachable.stderr | str trim)"}
    }

    let window = (worker-window-name $role $subject $project)
    # NOT `$task | default $subject`. `default` substitutes for null, not for an
    # empty string, so an AKM stage with no task would have allocated a worktree
    # named `bd-.0`; worse, nushell raises on `default` applied to a plain string
    # and reports it as the entirely unrelated "External command failed", which
    # is how this sat hidden behind a passing-looking spawn.
    let subject_for_branch = (if ($task | is-empty) { $subject } else { $task })
    let tree = (worktree-allocate --repo $repo --task $subject_for_branch)

    bus-identity $uid --run $run --identity {
        role: $role
        cwd: $tree.path
        branch: $tree.branch
        session: $session
        skill: $skill
        window: $window
    }

    # `remain-on-exit on` keeps a crashed or finished worker's window in place.
    # Without it a Pi that fails during startup takes its own error message off
    # the screen, and the operator is left with a missing window and no reason.
    # The worker's identity reaches the extension as environment, not as a
    # message: the extension needs to know which inbox is its own BEFORE any
    # message can be delivered, and a bootstrap message would have nowhere to
    # arrive. `new-window -e` sets these on the window's own environment only,
    # so nothing leaks into the operator's other windows.
    let worker_env = [
        "-e" $"INFINIFU_RUN=($run)"
        "-e" $"INFINIFU_UID=($uid)"
        "-e" $"INFINIFU_ROLE=($role)"
        "-e" $"INFINIFU_BRANCH=($tree.branch)"
        "-e" $"INFINIFU_SESSION=($session)"
        "-e" $"INFINIFU_SKILL=($skill)"
        "-e" $"INFINIFU_WINDOW=($window)"
    ]
    let created = (do {
        ^tmux ...(tmux-args $socket) new-window -d -t $project -n $window -c $tree.path ...$worker_env "pi" "--session" $session
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
        live: (worker-live? $window --socket $socket)
    }
}

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
export def worker-inspect [uid: string, --run: string]: nothing -> record {
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
        resume: $"pi --session ($identity.session)"
    }
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
# AKM-shaped message — it is prose, and a work payload may carry only a ticket
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

    worktree-cleanup --repo $repo --path $seen.identity.cwd --branch $seen.identity.branch --accepted
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
