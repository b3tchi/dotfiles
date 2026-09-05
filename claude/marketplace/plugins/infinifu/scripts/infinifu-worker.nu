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
