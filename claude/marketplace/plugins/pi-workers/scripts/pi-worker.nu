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
export const OBSERVATIONAL_VERDICTS = ["unknown" "gone"]

# A subject is worn as a tmux window name and a git branch name, so it is an
# address rather than a description. Long enough to be meaningful, short enough
# that `impl-<subject>@<project>` still reads in a window list.
export const MAX_SUBJECT_CHARS = 40

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

# Stages that take the other kind of payload, for a refusal to point at.
#
# A refusal is where the caller actually learns the vocabulary — observed all
# evening: an agent tried stage `default`, then `work-do`, then `build`, and
# learned the real names only from being told no. Saying "this stage wants a
# ticket" without saying which stage wants prose leaves the caller to guess
# again, and there may be no such stage at all — which is worth knowing,
# because then the registry is the thing to fix, not the call.
def stages-taking [shape: string]: nothing -> string {
    let matching = (load-stages | where payload == $shape | get name)
    if ($matching | is-empty) {
        $"no stage in the registry takes ($shape); the registry needs one"
    } else {
        $matching | str join ", "
    }
}

def validate-inbox-payload [payload: record, --stored] {
    if "stage" not-in ($payload | columns) {
        error make {msg: "inbox payload must name its stage"}
    }
    let stage = $payload.stage
    let fields = ($payload | columns)

    # A STORED envelope is history, and history is not re-litigated against
    # today's registry.
    #
    # This was found the hard way: renaming a stage in the registry made every
    # envelope written under the old name unreadable, because read-box
    # re-validates on read and validation resolved the stage. `inspect`,
    # `wait` and `ps` all died on a worker whose only crime was predating the
    # rename —
    #
    #     invalid envelope 1.json in .../inbox: unknown stage 'task': not one
    #     of probe, work, build
    #
    # Editing a config file must not corrupt the record of what already
    # happened. Validating a payload's SHAPE needs the registry, so that check
    # belongs where the envelope is written — where the gate can still refuse —
    # and not where it is read back.
    if $stored { return }

    # A bus-authored stage carries instructions by construction.
    let shape = (if $stage in $RESERVED_STAGES { "instructions" } else { stage-for $stage | get payload })
    if $shape == "ticket" {
        if "task" not-in $fields {
            error make {msg: $"payload for '($stage)' must carry its ticket id. If the work has no ticket and is prose, it needs a stage that takes instructions: (stages-taking 'instructions')"}
        }
        let extra = ($fields | where {|f| $f not-in $WORK_PAYLOAD_ALLOWED })
        if ($extra | is-not-empty) {
            error make {msg: $"payload for '($stage)' may carry only stage and task; found ($extra | str join ', '). A ticket payload is an address, so any copied body is a second source of truth"}
        }
    } else {
        if "task" in $fields {
            error make {msg: $"payload for '($stage)' must not carry a ticket id: this stage receives direct instructions and artifact ids. Stages that take a ticket: (stages-taking 'ticket')"}
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
export def validate-envelope [envelope: record, --stored] {
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
        "inbox" => { validate-inbox-payload $envelope.payload --stored=$stored }
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
        # `--stored`: the structure is still checked, but the stage is not
        # re-resolved against a registry that may have changed since.
        try { validate-envelope $parsed --stored } catch {|e|
            error make {msg: $"invalid envelope ($n | path basename) in ($dir): ($e.msg)"}
        }
        $envelopes = ($envelopes | append $parsed)
    }
    $envelopes
}

# The `Z` means UTC, so the value has to BE UTC.
#
# Without `to-timezone UTC` this formatted local wall clock and labelled it Z,
# putting every envelope out by the machine's offset. Ordering still looked
# right on one host — bus-pending sorts on this field — and would invert the
# moment two hosts in different zones wrote into the same run. A timestamp that
# lies about its zone is worse than no timestamp.
def now-stamp []: nothing -> string {
    date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%S%.6fZ"
}

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

    # A `complete` from an isolated worktree must be COMMITTED.
    #
    # Observed: a worker created its file, reported `complete`, and acceptance
    # then refused —
    #
    #     accept refused: refusing to clean up .../wk-timestamp-file.1: it
    #     holds uncommitted work, which acceptance does not license deleting
    #
    # — which is the right refusal at the wrong moment. By then the worker has
    # already declared success and gone quiet, so the operator is left holding
    # a finished worker that cannot be accepted and a worktree that cannot be
    # cleaned. Refusing at the REPORT puts the problem in front of the only
    # party that can fix it, while it is still working.
    #
    # This is the same failure work-do's Step 7 exists for: work-merge merges
    # the branch, not the worktree, so an uncommitted worktree is a branch with
    # zero commits and a merge that silently does nothing. The work survives
    # only because `git worktree remove` refuses to delete dirty state.
    #
    # Only `complete` is gated. `blocked`, `failed` and `waiting_human` are
    # exactly the statuses a worker should be able to report with a messy tree,
    # and refusing those would leave it no way to say so.
    #
    # A tree we cannot inspect is NOT refused: git missing, or a cwd that is not
    # a repository, is our failure to observe rather than the worker's failure
    # to commit, and accept's own guard still stands behind this. adr0017's
    # rule, applied to a gate rather than a verdict.
    if (($result | get -o status) == "complete") and ((stage-for $identity.skill | get isolation) == "worktree") {
        let dirty = (do { ^git -C $identity.cwd status --porcelain } | complete)
        if $dirty.exit_code == 0 and ($dirty.stdout | str trim | is-not-empty) {
            let files = ($dirty.stdout | lines | each {|l| $l | str trim } | first 5 | str join ", ")
            error make {msg: $"refusing `complete` from ($run)/($uid): ($identity.cwd) holds uncommitted work \(($files)). Commit it on ($identity.branch) first — acceptance deletes this worktree, and an uncommitted branch merges as a no-op, so reporting complete now loses the work"}
        }
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
# ------------------------------------------------------------- minting
#
# An agent that must supply an address and has no way to produce one shells out
# for it — observed live as a bare `uuidgen` line in the operator's transcript,
# which is 36 characters of noise that buys nothing to look at. The tool mints
# the address instead.
#
# `<role>-<n>` rather than a uuid because this name is worn in public: it is
# the tmux window, the frame's row, and the thing an operator says out loud.
# `impl-2` survives all three; `0a77b1d8-3eed-4ff0-8bda-78159973b144` does not.

# The lowest free `<role>-<n>` in a run.
export def mint-uid [run: string, role: string]: nothing -> string {
    let prefix = (if ($role | is-empty) { "w" } else { $role })
    let dir = (bus-root | path join $run)
    let taken = (if ($dir | path exists) {
        ls $dir | where type == dir | get name | each {|d| $d | path basename }
    } else { [] })
    mut n = 1
    while $"($prefix)-($n)" in $taken { $n = $n + 1 }
    $"($prefix)-($n)"
}

# The tmux session group to host a worker's window.
#
# Derived rather than demanded. The orchestrator is itself running in a tmux
# session, and that session's group is where the operator is already looking —
# which is the only sensible place to put a window they are meant to see. It
# was a required argument, and the refusal for omitting it was the last piece
# of ceremony left in a spawn call:
#
#     spawn refused: spawn needs --project: the tmux session group to host the
#     window, e.g. dotfiles
#
# Nothing about that is a decision the caller was making.
#
# Found from $TMUX_PANE via `list-panes`, deliberately NOT via
# `display-message`. That verb is on the forbidden list because `-p` makes it a
# read channel that could carry state, and the static guard enforces it — the
# right answer is not to argue for an exception but to use the probe that is
# already allowed and already used by worker-liveness.
#
# Keyed on the pane rather than on "the current session", because tmux ANSWERS
# either way: asked from outside, it reports whichever session was most
# recently active, which is a guess. A worker window placed in a guessed group
# is one the operator will not find. No $TMUX_PANE means no derivation, and the
# caller is told which flag to pass.
#
# A grouped session lists its pane once per member, all with the same group, so
# the first row is as good as any. An ungrouped session reports an empty group
# and its own name is the host.
export def current-session-group []: nothing -> string {
    let pane = ($env | get -o TMUX_PANE | default "")
    if ($pane | is-empty) { return "" }
    let listed = (do { ^tmux list-panes -a -F "#{pane_id}\t#{session_group}\t#{session_name}" } | complete)
    if $listed.exit_code != 0 { return "" }
    let mine = (
        $listed.stdout
        | lines
        | each {|l| $l | split row "\t" }
        | where {|r| ($r | length) >= 3 and ($r | first | str trim) == $pane }
    )
    if ($mine | is-empty) { return "" }
    let row = ($mine | first)
    let group = ($row | get 1 | str trim)
    if ($group | is-not-empty) { $group } else { $row | get 2 | str trim }
}

# The git repository enclosing the current directory.
#
# Same reasoning as the session group: the orchestrator is standing in a
# repository, and that is the one it means. Empty when it is not, so the caller
# gets a named refusal rather than a worker pointed somewhere arbitrary.
export def current-repo []: nothing -> string {
    let top = (do { ^git rev-parse --show-toplevel } | complete)
    if $top.exit_code != 0 { return "" }
    $top.stdout | str trim
}

# A fresh id for the worker's Pi session.
#
# Passed to `pi --session-id` to CREATE a session, so it only has to be unique
# — there is nothing to look up and nothing for a caller to know. The tool
# parameter used to be documented as "a fresh uuid for the worker's Pi
# session", which is an instruction to go and find one: the agent shelled out
# to `uuidgen` and the operator got a bare 36-character line for their trouble.
export def mint-session []: nothing -> string {
    random uuid
}

# The lowest free `r<n>` at the bus root.
#
# Directories that are not shaped `r<n>` are ignored rather than parsed: a run
# an operator named `x4` says nothing about which `r<n>` is free, and reading a
# number out of it would hand back an address already in use.
export def mint-run []: nothing -> string {
    let root = (bus-root)
    let taken = (if ($root | path exists) {
        ls $root | where type == dir | get name | each {|d| $d | path basename }
    } else { [] })
    mut n = 1
    while $"r($n)" in $taken { $n = $n + 1 }
    $"r($n)"
}

# Poll interval for a blocking wait. Short enough that a worker finishing feels
# immediate, long enough that a directory listing four times a second is not
# what the machine is doing with its life.
const WAIT_POLL = 250ms

export def bus-wait [
    --run: string
    --uid: string = ""
    --json
    # Without --block this peeks and answers at once, which is what a script
    # doing its own loop needs. WITH it, the verb does what its name says.
    #
    # It did not, and that had a cost: an agent told to "`wait` for its typed
    # result" called it, got nothing, decided out loud that it needed a polling
    # mechanism, and polled the worker's tmux pane — the one thing the
    # transport boundary forbids as a completion signal. A verb named `wait`
    # that does not wait sends the caller looking for a channel that is not the
    # bus.
    --block
    # Bounded, and bounded low: this runs inside a host tool call, and a wait
    # that outlives the host's own timeout is indistinguishable from a hang.
    --timeout: duration = 60sec
]: nothing -> any {
    let deadline = (date now) + $timeout
    loop {
        # Unscoped, this is the oldest unacknowledged result ACROSS the run,
        # which is what an orchestrator draining many workers wants. `--uid`
        # narrows it to one, which is what anyone waiting on a PARTICULAR
        # worker wants: a run that still holds a finished worker with an unacked
        # envelope would otherwise hand its answer to whoever asked next
        # (dotfiles-idzp's stale-state shape, in the mailbox rather than the
        # window list).
        let all = (bus-pending $run)
        let pending = (if ($uid | is-empty) { $all } else { $all | where uid == $uid })
        if ($pending | is-not-empty) {
            let next = ($pending | first)
            return (if $json { $next | to json } else { $next })
        }
        if not $block { return null }
        # Checked before sleeping, so a timeout of zero returns at once rather
        # than costing one interval.
        if (date now) >= $deadline { return null }
        sleep $WAIT_POLL
    }
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
# The one place a worker's state is decided.
#
# Extracted from bus-status so the timeline can say what the state was after
# each event without a second implementation of these rules. Two copies of a
# precedence table is two answers to "what is this worker" the first time
# someone edits one — and the whole reason the timeline is worth having is
# that it agrees with the frame.
#
# Pure: takes the evidence, returns the verdict, touches no disk.
#
# `markers` is {accepted?: bool, stopped?: bool, waiting_human?: bool,
# reopened?: string}; `results` is the outbox, oldest first.
export def derive-state [results: list<record>, markers: record]: nothing -> string {
    # Externally granted states win over anything the worker reported: a
    # reviewer's acceptance or an operator's teardown is later, and more
    # authoritative, than the worker's own last word about itself.
    if ($markers | get -o accepted | default false) { return "accepted" }
    if ($markers | get -o stopped | default false) { return "stopped" }
    if ($markers | get -o waiting_human | default false) { return "waiting_human" }

    let newest = (if ($results | is-empty) { 0 } else { $results | last | get sequence })
    # `reopened` is the subtle one. A rejected worker's last envelope still
    # says `complete` — that report was true when it was written — so the
    # marker records WHICH result was sent back. While it covers the newest
    # result, the worker is running again; once the worker reports afresh, the
    # newer sequence outranks the marker and its real outcome shows through.
    let reopened = ($markers | get -o reopened | default "")
    if ($reopened | is-not-empty) and (($reopened | into int) >= $newest) { return "running" }

    # Spawned and has never reported. `created` is the declared WORKER_STATE
    # for exactly this: alive and has not said anything yet, which needs a
    # different response from "reported once and was sent back to work".
    if ($results | is-empty) { return "created" }

    # Dispatch on KIND, not on a field. An outbox holds `result` envelopes
    # (payload.status) and `error` envelopes (payload.code) — different shapes
    # — so reading `payload.status` off whatever came last crashed with
    # "column 'status' is missing" the first time a worker settled without
    # reporting.
    let latest = ($results | last)
    if $latest.kind == "error" { $latest.payload.code } else { $latest.payload.status }
}

# The markers that bear on a worker's state, as derive-state wants them.
def state-markers [run: string, uid: string]: nothing -> record {
    {
        accepted: (marker-path $run $uid "accepted" | path exists)
        stopped: (marker-path $run $uid "stopped" | path exists)
        waiting_human: (marker-path $run $uid "waiting_human" | path exists)
        reopened: (marker-value $run $uid "reopened")
    }
}

export def bus-status [uid: string, --run: string]: nothing -> record {
    let dir = (worker-dir $run $uid)
    if not ($dir | path exists) {
        return {run: $run, uid: $uid, state: "unknown", unacked: 0, results: 0, inbox: 0}
    }
    let results = (read-box ($dir | path join "outbox"))
    let unacked = ($results | where {|e| not (ack-path $run $uid $e.sequence | path exists) })
    # The precedence rules, and the reasoning for them, live with derive-state.
    let state = (derive-state $results (state-markers $run $uid))
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

# The worker's current identity ENVELOPE, or nothing if none was recorded.
#
# Separate from `bus-identity-of` because the envelope carries the `created`
# stamp and the payload does not. That stamp is the only record of when a
# worker was spawned, so anything asking "how long has this been running"
# needs the envelope rather than what is inside it.
export def bus-identity-envelope [uid: string, --run: string]: nothing -> any {
    let dir = (worker-dir $run $uid | path join "identity")
    let records = (read-box $dir)
    if ($records | is-empty) { return null }
    $records | last
}

# The worker's current identity, or nothing if it was never recorded.
export def bus-identity-of [uid: string, --run: string]: nothing -> any {
    let envelope = (bus-identity-envelope $uid --run $run)
    if $envelope == null { return null }
    $envelope | get payload
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
#   gone     tmux answered, and there is no such window
#   unknown  tmux could not be reached — nobody watched, so nothing was
#            observed
#
# `gone` and `unknown` were one verdict, and that was the bug adr0017 exists to
# prevent: "sharing a code between 'dead' and 'cannot tell' is precisely the
# bug this prevents". A worker whose window had been reaped read the same as
# one on a box where tmux was down, and since `unknown` correctly never
# licenses cleanup, it sat at `running` forever. Splitting them makes
# `running`/`gone` legible as "died without reporting" — the case that needs a
# human — where before it was indistinguishable from "ask again later".
#
# `unknown` and `gone` are both OBSERVATIONAL verdicts: never persisted, never
# reportable by a worker about itself. Neither licenses automatic cleanup —
# `gone` is tmux's evidence about a window, not the worker's about its work,
# and adr0017 reserves automatic recovery for the latter. So `gone` is
# REPORTED, and a human decides.
#
# Nor is `exited` a licence — knowing a process stopped is not knowing the work
# is finished.
export def worker-liveness [window: string, --socket: string = ""]: nothing -> record {
    # A window_id (@N) is matched exactly; a name is matched as before, so an
    # identity written before ids were recorded is still addressable rather than
    # stranded.
    let by_id = ($window | str starts-with "@")
    let fmt = (if $by_id { "#{window_id}\t#{pane_dead}" } else { "#{window_name}\t#{pane_dead}" })
    let listed = (do { ^tmux ...(tmux-args $socket) list-panes -a -F $fmt } | complete)
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
        # tmux ANSWERED. That the window is absent is a finding, not a failure
        # to observe, and calling it `unknown` threw that away.
        return {verdict: "gone", window: $window, reason: "tmux has no such window; it was closed or reaped"}
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

# How to address a worker's window: its id when one was recorded, its name
# otherwise. Callers use this rather than reaching for identity.window, so an
# older identity keeps working and a newer one is never addressed ambiguously.
export def window-target [identity: record]: nothing -> string {
    let id = ($identity | get -o window_id | default "")
    if ($id | is-empty) { $identity.window } else { $id }
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
    # An address is claimed once. Spawning onto an occupied one used to inherit
    # the previous occupant's mail: the first message got a sequence continuing
    # someone else's, `wait` returned THEIR result envelope, and a stale
    # `stopped` marker made teardown a no-op. The initiator then reported a
    # result its worker never produced, which is the worst kind of wrong — it
    # looks like success.
    #
    # Refused rather than cleared: the old envelopes may be the only record of
    # what the previous worker did, and deleting evidence to make room is not
    # this command's call.
    let existing = (worker-dir $run $uid)
    if ($existing | path exists) {
        error make {msg: $"($run)/($uid) already exists: that address has been used, and spawning onto it would inherit its mail and markers. Use a different uid, or release this one with `rm --run ($run) --uid ($uid)` once it is finished with"}
    }

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
    # A worker sharing the operator's tree is stopped from committing to it;
    # see write-commit-guard. An isolated worker owns its branch and must be
    # able to commit, so it gets nothing here.
    let commit_guard = (if not $tree.isolated {
        let hooks = (write-commit-guard $run $uid $skill $tree.branch)
        [
            "-e" "GIT_CONFIG_COUNT=1"
            "-e" "GIT_CONFIG_KEY_0=core.hooksPath"
            "-e" $"GIT_CONFIG_VALUE_0=($hooks)"
        ]
    } else { [] })

    let worker_env = ([
        "-e" $"PI_WORKER_RUN=($run)"
        "-e" $"PI_WORKER_UID=($uid)"
        "-e" $"PI_WORKER_ROLE=($role)"
        "-e" $"PI_WORKER_BRANCH=($tree.branch)"
        "-e" $"PI_WORKER_SESSION=($session)"
        "-e" $"PI_WORKER_SKILL=($skill)"
        "-e" $"PI_WORKER_WINDOW=($window)"
    ] ++ $commit_guard)
    # `-P -F #{window_id}` makes new-window print the id it assigned. That id is
    # how every later operation addresses this worker: a NAME is ambiguous the
    # moment two runs share a role and subject, and tmux then targets whichever
    # window it finds first — which is how a stop closed the wrong worker
    # (dotfiles-idzp). An id is also free of the `.` that made a ticket-shaped
    # subject unparseable (dotfiles-pnxw).
    let created = (do {
        ^tmux ...(tmux-args $socket) new-window -d -P -F "#{window_id}" -t $target -n $window -c $tree.path ...$worker_env "pi" "--session-id" $session
    } | complete)
    if $created.exit_code != 0 {
        error make {msg: $"tmux could not create window ($window): ($created.stderr | str trim)"}
    }
    let window_id = ($created.stdout | str trim)
    # FIRST, before anything slower: a worker whose command fails instantly is
    # exactly the one whose error must stay on screen, and every millisecond
    # between creating the window and setting this is a window in which a fast
    # exit destroys it and takes the reason with it.
    do { ^tmux ...(tmux-args $socket) set-option -t $window_id remain-on-exit on } | complete | ignore

    # Pin the pane, or this repo's own housekeeping deletes the worker.
    #
    # `nushell/actions/tmux-cleanup` reaps unattached windows that have no pane
    # with `@pinned` set to "1", and a worker window is created with
    # `new-window -d` — detached by definition, since the whole point is that
    # the operator is working elsewhere. Observed in ~/.tmux.log:
    #
    #     04:44:52 - Killing unattached window - no pinned panes: @223
    #     04:55:39 - Killing unattached window - no pinned panes: @229
    #
    # The worker died mid-task, its window vanished, and because liveness has
    # no way to distinguish that from "tmux could not be asked", the bus left
    # it `running` forever. The operator saw a worker running for five minutes
    # with no window anywhere on the machine.
    #
    # [[poc022]] said this before sp028 shipped: "Match the existing
    # `tmux-start` group construction, identify workers through explicit pane
    # options". `tmux-start` sets `@pinned` on every pane it creates; this is
    # the same convention, applied by the one thing that also creates panes.
    #
    # Not a transport-boundary violation: `@pinned` carries no message, no
    # completion signal and no coordination state. It tells the DISPLAY host
    # not to reap a window — which is exactly the "tmux hosts and displays
    # workers" half of that rule, not the bus half.
    #
    # Set immediately after remain-on-exit, and before anything slower, for the
    # same reason: the gap between creating a window and protecting it is a gap
    # in which it can be destroyed.
    do { ^tmux ...(tmux-args $socket) set-option -p -t $window_id "@pinned" "1" } | complete | ignore

    # Re-record the identity now that the id exists. Written twice rather than
    # deferred: the first write is what leaves a resume handle behind when the
    # window never gets created at all.
    bus-identity $uid --run $run --identity {
        role: $role
        cwd: $tree.path
        branch: $tree.branch
        session: $session
        skill: $skill
        window: $window
        window_id: $window_id
    }

    {
        run: $run
        uid: $uid
        role: $role
        window: $window
        window_id: $window_id
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
        live: (worker-live? $window_id --socket $socket)
        liveness: (worker-liveness $window_id --socket $socket | get verdict)
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

# Every worker the bus knows about, across every run.
#
# The question an operator actually asks is "what is running and where do I
# find it?", and answering it used to require knowing the run id first. This
# carries only what locating a worker needs — who it is, whether it is alive,
# the window to look at, the command to open its transcript — and leaves the
# envelopes, counts and history to `inspect`.
#
# `liveness` needs tmux; when tmux cannot be reached it reports `unknown`
# rather than guessing, so a roster is still useful without a display host.
export def worker-roster [--run: string = "", --socket: string = ""]: nothing -> list<record> {
    let root = (bus-root)
    if not ($root | path exists) { return [] }

    let runs = (if ($run | is-empty) {
        ls $root | where type == dir | get name | sort | each {|d| $d | path basename }
    } else { [$run] })

    $runs | each {|r|
        let dir = ($root | path join $r)
        if not ($dir | path exists) { [] } else {
            ls $dir | where type == dir | get name | sort | each {|w|
                let uid = ($w | path basename)
                let envelope = (bus-identity-envelope $uid --run $r)
                let identity = (if $envelope == null { null } else { $envelope.payload })
                let window = (if $identity == null { "" } else { $identity.window })
                let target = (if $identity == null { "" } else { window-target $identity })
                {
                    run: $r
                    uid: $uid
                    role: (if $identity == null { "" } else { $identity.role })
                    state: (bus-status $uid --run $r | get state)
                    liveness: (if ($target | is-empty) { "unknown" } else { worker-liveness $target --socket $socket | get verdict })
                    window: $window
                    # When the worker was spawned. Empty rather than a
                    # substitute when no identity was ever written: a made-up
                    # start time would read as an idle worker.
                    started: (if $envelope == null { "" } else { $envelope.created })
                    resume: (if $identity == null { "" } else { resume-hint $identity })
                }
            }
        }
    } | flatten
}

# Refuse commits from a worker that shares the operator's working tree.
#
# A stage with `isolation: main` puts the worker in the repo the operator is
# using, on whatever branch they are on. Six commits reached this repo's `main`
# that way in one evening, five files of them still tracked and pushed, because
# nothing stopped a worker doing the most ordinary thing a coding agent does.
#
# Guidance alone will not hold. `promptGuidelines` tells the worker not to, and
# a worker that decides committing is the helpful thing will commit anyway —
# the same reason `complete` is gated at the bus rather than requested in
# prose. So this is a git hook, and git enforces it.
#
# Delivered as `core.hooksPath` through GIT_CONFIG_* environment variables,
# which git honours per-process: nothing is written to the repo's config, the
# operator's own hooks are untouched, and the setting dies with the window.
#
# GENERATED into the worker's runtime directory rather than shipped as a file
# in this package, because the CLI is reached through a symlink in ~/.local/bin
# and a script cannot reliably find its own package directory from there — the
# same resolution problem install.sh works around for `use`.
#
# A worktree-isolated worker gets NO hook: it owns a throwaway branch and MUST
# commit, and bus-result refuses its `complete` if it has not.
export def write-commit-guard [run: string, uid: string, skill: string, branch: string]: nothing -> string {
    let dir = (worker-dir $run $uid | path join "githooks")
    ensure-dir $dir
    let refusal = ([
        "#!/usr/bin/env bash"
        "# Generated by pi-worker for a stage with isolation: main."
        "cat >&2 <<'MSG'"
        $"refusing to commit: this worker runs in the operator's own working tree."
        $""
        $"  stage:  ($skill)  \(isolation: main)"
        $"  branch: ($branch)"
        $""
        "A commit here lands on the operator's branch, not on a branch of your"
        "own. If this work needs committing, it needs a stage declared with"
        "isolation: worktree. If it does not, report your outcome without"
        "committing — or report blocked and say what you needed."
        "MSG"
        "exit 1"
    ] | str join "\n")
    for hook in ["pre-commit" "pre-push"] {
        let path = ($dir | path join $hook)
        $refusal | save -f $path
        chmod 700 $path
    }
    $dir
}

# Everything that happened to one worker, in order.
#
# Reconstructed, not recorded: every envelope already carries a `created`
# stamp and every marker's CONTENT is a stamp, so the history is on the bus
# already and this only reads it. Nothing new is written, which matters — a
# timeline that needed its own log would be a second source of truth about
# what happened, and would disagree with the envelopes the moment one was
# written and the other was not.
#
# The deltas are the point. A worker's wall-clock life is easy to see in the
# frame; where the time WENT is not, and the answer is usually one gap —
# thirty seconds between `sent` and `reported` is the agent thinking, thirty
# seconds between `reported` and `acked` is the orchestrator not listening.
export def worker-timeline [uid: string, --run: string]: nothing -> list<record> {
    let dir = (worker-dir $run $uid)
    if not ($dir | path exists) { return [] }

    let identity = (
        read-box ($dir | path join "identity")
        | enumerate
        | each {|e|
            {
                at: $e.item.created
                class: "identity"
                envelope: null
                value: ""
                event: (if $e.index == 0 { "spawned" } else { "identity" })
                detail: (
                    if $e.index == 0 {
                        $"($e.item.payload.window) · branch ($e.item.payload.branch) · ($e.item.payload.cwd)"
                    } else {
                        # The re-record exists to add the window id tmux chose.
                        $"window_id ($e.item.payload | get -o window_id | default '?')"
                    }
                )
            }
        }
    )

    let inbox = (
        read-box ($dir | path join "inbox")
        | each {|e|
            let payload = $e.payload
            let what = (if ("task" in ($payload | columns)) {
                $"ticket ($payload.task)"
            } else {
                $"($payload | get -o instructions | default '' | str length) chars of instructions"
            })
            {at: $e.created, class: "inbox", envelope: null, value: "", event: $"sent seq ($e.sequence)", detail: $"stage ($payload.stage) · ($what)"}
        }
    )

    let outbox = (
        read-box ($dir | path join "outbox")
        | each {|e|
            let payload = $e.payload
            let verdict = (if $e.kind == "error" {
                $"($payload | get -o code | default 'error'): ($payload | get -o detail | default '')"
            } else {
                $"($payload | get -o status | default '?') — ($payload | get -o summary | default '')"
            })
            {at: $e.created, class: "result", envelope: $e, value: "", event: $"reported seq ($e.sequence)", detail: $verdict}
        }
    )

    # An ack is a file whose name is the sequence and whose body is the stamp.
    let acks = (
        glob ($dir | path join "outbox" "*.ack")
        | each {|f|
            {
                at: (open --raw $f | str trim)
                class: "ack"
                envelope: null
                value: ""
                event: $"acked seq ($f | path basename | str replace '.ack' '')"
                detail: "receipt, not acceptance"
            }
        }
    )

    let markers = (
        glob ($dir | path join "*.marker")
        | each {|f|
            let name = ($f | path basename | str replace ".marker" "")
            let body = (open --raw $f | str trim)
            # `reopened` stores the sequence it covers rather than a stamp, so
            # it has no time of its own to sort by; the file's mtime is the
            # honest answer for it.
            let stamped = (if ($body =~ '^\d{4}-\d{2}-\d{2}T') { $body } else { ls $f | get 0.modified | format date "%Y-%m-%dT%H:%M:%S%.6fZ" })
            {at: $stamped, class: "marker", envelope: null, value: $body, event: $name, detail: (if $body == $stamped { "" } else { $"covers seq ($body)" })}
        }
    )

    let events = ([$identity $inbox $outbox $acks $markers] | flatten | sort-by at)
    if ($events | is-empty) { return [] }

    let first = ($events | first | get at | into datetime)

    # The state column is REPLAYED, not recorded: the evidence up to each event
    # is handed to the same derive-state the frame asks. So the timeline cannot
    # disagree with the row above it — and where it changes state is where the
    # frame changed too, which is the whole point of putting them side by side.
    #
    # A `reopened` marker is the one event whose position in time is a guess
    # (its body holds a sequence, not a stamp, so the file's mtime stands in),
    # and it is also the one that can move state backwards to `running`. Worth
    # knowing when reading a rejected worker's history.
    $events
    | reduce --fold {results: [], markers: {}, out: []} {|e, acc|
        let results = (if $e.class == "result" { $acc.results | append $e.envelope } else { $acc.results })
        let markers = (if $e.class == "marker" {
            if $e.event == "reopened" {
                $acc.markers | upsert reopened $e.value
            } else {
                $acc.markers | upsert $e.event true
            }
        } else { $acc.markers })
        {
            results: $results
            markers: $markers
            out: ($acc.out | append {
                at: $e.at
                "+s": (((($e.at | into datetime) - $first) / 1sec | math round --precision 1))
                event: $e.event
                state: (derive-state $results $markers)
                detail: $e.detail
            })
        }
    }
    | get out
}

# Let go of a finished worker's address.
#
# The occupied-address guard claims an address for the life of the run
# directory, so repeating a run otherwise needs a fresh id every time. This is
# the deliberate way to reuse one.
#
# Refused while the worker is unfinished: its envelopes may be the only record
# of what it did, and `running`, `blocked` or `waiting_human` all mean something
# may still be waiting on it. Only a terminal worker is discardable.
export def worker-release [--run: string, --uid: string]: nothing -> record {
    let dir = (worker-dir $run $uid)
    if not ($dir | path exists) {
        return {run: $run, uid: $uid, removed: false, reason: "no such worker"}
    }
    let state = (bus-status $uid --run $run | get state)
    if $state not-in ["stopped" "accepted"] {
        error make {msg: $"refusing to release ($run)/($uid): it is ($state), and its envelopes may be the only record of what it did. Stop or accept it first"}
    }
    rm -rf $dir
    # A run directory with nothing left in it is just clutter.
    let run_dir = (run-dir $run)
    if ($run_dir | path exists) and ((ls $run_dir | length) == 0) { rm -rf $run_dir }
    {run: $run, uid: $uid, removed: true, state: $state}
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
]: nothing -> record {
    let seen = (worker-inspect $uid --run $run)
    # Idempotent for the same reason stop is: a retried acceptance has nothing
    # left to do, and the worktree it would have reclaimed is already gone.
    if $seen.state == "accepted" {
        return {run: $run, uid: $uid, state: "accepted", changed: false, reason: "already accepted"}
    }
    validate-transition $seen.state "accepted"

    # The window closes first: it is recoverable (spawn again from the session
    # id), whereas the worktree is not, so the irreversible step goes last.
    do { ^tmux ...(tmux-args $socket) kill-window -t (window-target $seen.identity) } | complete | ignore

    # An isolation=main stage runs IN the main worktree, shared with the operator
    # and is nobody's to delete. There is no isolated directory or task branch
    # to reclaim, so acceptance is the marker alone.
    if $seen.identity.cwd != (main-worktree $repo) {
        worktree-cleanup --repo $repo --path $seen.identity.cwd --branch $seen.identity.branch --accepted
    }
    write-marker $run $uid "accepted"
    {run: $run, uid: $uid, state: "accepted", changed: true}
}

# Tear a worker down without accepting its work.
#
# Stopping closes the window and nothing else. The worktree may hold unmerged
# commits, so it stays until something explicitly says the work is finished
# with — `stopped` is terminal, and a stopped worker can never become
# `accepted`.
# Tear a worker down without accepting its work.
#
# Idempotent. An initiator that retries — after a timeout, or because it lost
# track of what it had already torn down — must not be told it did something
# illegal for asking to stop something already stopped. The state is terminal,
# so the second call has nothing to do.
#
# That is not permission to re-enter a terminal state: an ACCEPTED worker still
# refuses to be stopped, because acceptance records that the work was taken and
# a later stop would rewrite what happened.
export def worker-stop [uid: string, --run: string, --socket: string = ""]: nothing -> record {
    let seen = (worker-inspect $uid --run $run)
    if $seen.state == "stopped" {
        return {run: $run, uid: $uid, state: "stopped", changed: false, reason: "already stopped"}
    }
    validate-transition $seen.state "stopped"
    do { ^tmux ...(tmux-args $socket) kill-window -t (window-target $seen.identity) } | complete | ignore
    write-marker $run $uid "stopped"
    {run: $run, uid: $uid, state: "stopped", changed: true}
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
        "  wait     --run [--uid]               oldest unacknowledged result, or nothing"
        "  rm       --run --uid                 release a finished worker's address"
        "  ack      --run --uid --sequence      delivery receipt; NOT acceptance"
        "  status   <uid> --run                 one worker's state, from the bus"
        "  liveness <uid> --run [--socket]      live | exited | unknown, from tmux"
        "  inspect  <uid> --run                 identity, last result, resume command"
        "  ps       [--run] [--socket]          every worker, where it is and whether it lives"
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

# `--run` and `--uid` are optional and minted when absent; the result names
# what was chosen, so a caller spawning siblings reads the run back off its
# first spawn instead of inventing one.
def "main spawn" [
    --run: string = "", --uid: string = "", --role: string = "", --subject: string
    --project: string = "", --repo: string = "", --session: string = "", --skill: string
    --task: string = "", --socket: string = ""
] {
    # Derived before the check below, so the caller is only asked for what
    # cannot be worked out from where it is standing.
    let project = (if ($project | is-empty) { current-session-group } else { $project })
    let repo = (if ($repo | is-empty) { current-repo } else { $repo })

    # Required arguments, refused BY NAME.
    #
    # These were declared `string` with no default, so omitting one propagated
    # a null inward until some helper died on it:
    #
    #     Error: nu::shell::cant_convert
    #       x Can't convert to string.
    #
    # which names no verb, no argument, and no remedy. An agent driving this
    # tool burned turns on it. A refusal has to say what is missing and what it
    # is for, or it is just a slower way of saying no.
    for required in [
        [flag       value       what];
        ["--role"   $role       "the worker's role, e.g. impl or rev; it appears in the window name"]
        ["--subject" $subject   "a short slug naming the work; it appears in the window name and the branch"]
        ["--project" $project   "the tmux session group to host the window. Normally derived from the session you are in — pass it only when running outside tmux"]
        ["--repo"    $repo      "the git repository the worker works in. Normally derived from the current directory — pass it only when that is not a repository"]
        ["--skill"   $skill     "which stage this worker runs; `pi-worker doctor` lists them"]
    ] {
        if ($required.value | is-empty) {
            error make {msg: $"spawn needs ($required.flag): ($required.what)"}
        }
    }

    # A subject becomes a tmux window name and a git branch, so it has to be a
    # NAME. Observed: an agent passed its entire task description —
    #
    #     "Create timestamp-named text file with header in /home/jan/.dotfiles.
    #      Filename must be current timestamp in safe format like ..."
    #
    # — and worktree-allocate spent 64 attempts failing to build a branch out
    # of it before giving up. The refusal was honest and the diagnosis was
    # impossible: nothing said the prose was the problem.
    #
    # Refused rather than slugified. Truncating would produce a window and a
    # branch named after the first few words of an instruction, which is worse
    # than being told: the caller meant that prose to reach the worker, and it
    # belongs in the message, not in an address.
    if ($subject | str length) > $MAX_SUBJECT_CHARS {
        error make {msg: $"spawn's --subject is ($subject | str length) characters; it names a tmux window and a git branch, so keep it under ($MAX_SUBJECT_CHARS). What the worker should DO belongs in the message, not in its address"}
    }
    if ($subject =~ '\s') {
        error make {msg: $"spawn's --subject may not contain whitespace: it names a tmux window and a git branch. Pass a slug like 'timestamp-file'; the instructions go in the message"}
    }

    # `--task` names the branch when it is given (see subject_for_branch in
    # worker-spawn), so it is under exactly the same constraint as --subject
    # and was under none of it. Observed: an agent put its whole instruction
    # prose here and got
    #
    #     could not allocate a worktree for Create a new text file in
    #     /home/jan/.dotfiles whose filename is the current timestamp ...
    #     after 64 attempts
    #
    # which is git refusing 64 candidate branch names and saying so at the
    # wrong altitude entirely.
    #
    # And the reason the prose went HERE is worth refusing separately: this
    # stage takes instructions, spawn has nowhere to put instructions, and
    # `--task` was the only field that looked like it accepted prose. Being
    # told which verb carries instructions is the answer the caller needed;
    # being told the branch allocator gave up is not.
    if ($task | is-not-empty) {
        let payload_kind = (stage-for $skill | get payload)
        if $payload_kind != "ticket" {
            error make {msg: $"spawn's --task is a TICKET ID and stage '($skill)' takes instructions, not a ticket. Spawn the worker without --task, then give it the work with `send --stage ($skill) --instructions '...'`"}
        }
        if ($task | str length) > $MAX_SUBJECT_CHARS {
            error make {msg: $"spawn's --task is ($task | str length) characters; it names the worker's git branch, so it must be a ticket id, not a description. What the worker should DO belongs in the message"}
        }
        if ($task =~ '\s') {
            error make {msg: $"spawn's --task may not contain whitespace: it names the worker's git branch. Pass a ticket id like 'dotfiles-2mzv'; the instructions go in `send --instructions`"}
        }
    }

    let run = (if ($run | is-empty) { mint-run } else { $run })
    let session = (if ($session | is-empty) { mint-session } else { $session })
    let minted = ($uid | is-empty)

    # Retried only when the address was MINTED. Two spawns racing for the same
    # run can each mint the same lowest-free uid, and the occupied-address
    # guard is the thing that notices. An explicitly passed uid gets no retry:
    # its refusal is the answer the caller asked for, and quietly spawning
    # somewhere else would be worse than failing.
    mut attempt = 0
    loop {
        let uid = (if $minted { mint-uid $run $role } else { $uid })
        let outcome = (try {
            {ok: true, value: (worker-spawn --run $run --uid $uid --role $role --subject $subject --project $project --repo $repo --task $task --session $session --skill $skill --socket $socket)}
        } catch {|e|
            {ok: false, error: $e}
        })
        if $outcome.ok {
            $outcome.value | to json | print
            return
        }
        $attempt = $attempt + 1
        if (not $minted) or $attempt >= 5 { error make $outcome.error.raw }
    }
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
#
# `--block` waits for one instead of peeking, which is how a caller finds out a
# worker finished. Reading its tmux window is NOT how: that window exists to be
# looked at by a person, and it carries no completion signal.
#
# `--timeout` is in seconds here rather than a duration, because the caller is
# usually a model writing flags and `--timeout 30` is harder to get wrong than
# `--timeout 30sec`.
def "main wait" [--run: string, --uid: string = "", --block, --timeout: int = 60] {
    let next = (bus-wait --run $run --uid $uid --block=$block --timeout ($timeout * 1sec))
    if $next != null {
        print ($next | to json)
    } else if $block {
        # A worker still working is not a failure, so this exits 0 and says so
        # in words the caller can act on rather than returning bare silence
        # that looks the same as "finished with nothing to say".
        let who = (if ($uid | is-empty) { "any worker" } else { $uid })
        print $"no result from ($run)/($who) after ($timeout)s; it may still be working"
    }
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
    # Probe by id (unambiguous), report the NAME (what an operator scans a
    # window list for), and carry the id so a caller can act on it.
    let seen = (worker-liveness (window-target $identity) --socket $socket)
    $seen | merge {window: $identity.window, window_id: ($identity | get -o window_id | default "")} | to json | print
}

def "main status" [uid: string, --run: string] { bus-status $uid --run $run | to json | print }
def "main inspect" [uid: string, --run: string] { worker-inspect $uid --run $run | to json | print }
# A table by default, JSON on request.
#
# Every other verb answers a machine, so JSON was the obvious default here too
# — and it is the wrong one. This verb exists to be READ: a human asking where
# a worker's time went, handed 60 lines of pretty-printed JSON, has been given
# the data and not the answer. The extension asks for --json; a person at a
# prompt gets columns.
def "main timeline" [uid: string, --run: string, --json] {
    let events = (worker-timeline $uid --run $run)
    if $json {
        $events | to json | print
    } else if ($events | is-empty) {
        print $"no events recorded for ($run)/($uid)"
    } else {
        $events | select "+s" event state detail | print
    }
}
def "main rm" [--run: string, --uid: string] {
    worker-release --run $run --uid $uid | to json | print
}

def "main ps" [--run: string = "", --socket: string = ""] {
    worker-roster --run $run --socket $socket | to json | print
}

def "main workers" [--run: string] { run-workers $run | to json | print }

def "main resume" [uid: string, --run: string, --feedback: string, --socket: string = ""] {
    worker-resume $uid --run $run --feedback $feedback --socket $socket | to json | print
}

def "main accept" [uid: string, --run: string, --repo: string, --socket: string = ""] {
    worker-accept $uid --run $run --repo $repo --socket $socket | to json | print
}

def "main stop" [uid: string, --run: string, --socket: string = ""] {
    worker-stop $uid --run $run --socket $socket | to json | print
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
