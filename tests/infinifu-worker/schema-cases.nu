#!/usr/bin/env nu
# Envelope schema cases (sp028 T1).
#
# Every envelope crossing the bus is versioned, sequenced, addressed and
# capped. These cases assert the validator rejects each way an envelope can be
# wrong, and — the half that is easy to forget — that it ACCEPTS the shapes the
# protocol actually needs, so a validator cannot pass this suite by rejecting
# everything.
#
# Emits a JSON case list on stdout; run-tests.nu aggregates.

use harness.nu *
use ../../claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu *

# 1 KiB of filler, used to build oversized payloads without a literal blob.
def filler [bytes: int]: nothing -> string {
    "x" | fill --width $bytes --character "x"
}

let cases = [
    # ---------------------------------------------------- accepts valid shapes
    (run-case "schema/accepts-work-stage-inbox" {
        validate-envelope (sample-envelope "inbox")
    })
    (run-case "schema/accepts-result" {
        validate-envelope (sample-envelope "result")
    })
    (run-case "schema/accepts-error" {
        validate-envelope (sample-envelope "error")
    })
    (run-case "schema/accepts-non-work-stage-inbox" {
        # ft013: AKM stages get direct instructions plus artifact ids, not a bd
        # ticket. Both payload shapes are legal; they are not interchangeable.
        validate-envelope (
            sample-envelope "inbox"
            | update payload {stage: "spec-refinement", instructions: "refine the spec", artifacts: ["sp028"]}
        )
    })

    # ------------------------------------------------------- required fields
    (run-case "schema/rejects-missing-protocol" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject protocol) } "protocol" "missing version must be named"
    })
    (run-case "schema/rejects-missing-sequence" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject sequence) } "sequence" "missing sequence must be named"
    })
    (run-case "schema/rejects-missing-run" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject run) } "run" "missing run id must be named"
    })
    (run-case "schema/rejects-missing-uid" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject uid) } "uid" "missing worker uid must be named"
    })
    (run-case "schema/rejects-missing-created" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject created) } "created" "missing timestamp must be named"
    })
    (run-case "schema/rejects-missing-payload" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject payload) } "payload" "missing payload must be named"
    })

    # --------------------------------------------------------- version + kind
    (run-case "schema/rejects-unknown-protocol-version" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | update protocol 2) } "protocol" "unknown version must be rejected"
    })
    (run-case "schema/rejects-unknown-kind" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | update kind "gossip") } "kind" "unknown kind must be rejected"
    })
    (run-case "schema/rejects-negative-sequence" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | update sequence (-1)) } "sequence" "sequence must be non-negative"
    })

    # ------------------------------------------------------------------ caps
    (run-case "schema/rejects-oversized-envelope" {
        assert-rejects {
            validate-envelope (
                sample-envelope "inbox"
                | update payload {stage: "spec-refinement", instructions: (filler 70000), artifacts: []}
            )
        } "64 KiB" "envelope cap must be enforced and named"
    })
    (run-case "schema/rejects-oversized-summary" {
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.summary (filler 5000))
        } "4 KiB" "summary cap must be enforced and named"
    })
    (run-case "schema/accepts-summary-at-the-cap" {
        # Off-by-one guard: the cap is inclusive, so exactly 4096 bytes passes.
        validate-envelope (sample-envelope "result" | update payload.summary (filler 4096))
    })

    # -------------------------------------------- work-stage payload contract
    (run-case "schema/rejects-copied-task-body-in-work-payload" {
        # sp028 anti-pattern: no copied bd task body in a work-stage message.
        # The worker reads its contract with `bd show <id>`; anything else in
        # the payload is a second, drifting source of truth.
        assert-rejects {
            validate-envelope (
                sample-envelope "inbox"
                | update payload {stage: "work-do", task: "dotfiles-963w.1", design: "implement the thing"}
            )
        } "work-do" "a work payload carrying prose must be rejected"
    })
    (run-case "schema/rejects-work-payload-without-task" {
        assert-rejects {
            validate-envelope (sample-envelope "inbox" | update payload {stage: "work-audit"})
        } "task" "a work payload must carry its bd task id"
    })
    (run-case "schema/rejects-non-work-payload-carrying-a-task" {
        # The two shapes stay distinct (ft013). An AKM stage addressed with a
        # bd ticket means the caller picked the wrong contract.
        assert-rejects {
            validate-envelope (
                sample-envelope "inbox"
                | update payload {stage: "spec-retro", task: "dotfiles-963w.1", instructions: "retro", artifacts: []}
            )
        } "spec-retro" "an AKM-stage payload must not carry a bd task id"
    })

    # ------------------------------------------------- result payload contract
    (run-case "schema/rejects-complete-without-validation-verdict" {
        # ft013: a delegated stage may not report completion before its own
        # required validation passes.
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.validation null)
        } "validation" "complete without a verdict must be rejected"
    })
    (run-case "schema/rejects-result-without-resume-command" {
        assert-rejects {
            validate-envelope (sample-envelope "result" | reject payload.resume)
        } "resume" "a result must carry its exact resume command"
    })
    (run-case "schema/rejects-unknown-result-status" {
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.status "finished")
        } "status" "an unknown result status must be rejected"
    })
    (run-case "schema/rejects-result-claiming-accepted" {
        # `accepted` is the initiator's verdict, never the worker's claim.
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.status "accepted")
        } "accepted" "a worker must not accept its own work"
    })
    (run-case "schema/rejects-result-claiming-unknown" {
        # adr0017: `unknown` is an observation, never a reported outcome.
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.status "unknown")
        } "unknown" "unknown is observational and cannot be reported as a result"
    })
    (run-case "schema/accepts-blocked-result-without-verdict" {
        # Only `complete` needs a verdict; a blocked worker reports why.
        validate-envelope (
            sample-envelope "result"
            | update payload.status "blocked"
            | update payload.validation null
        )
    })
]

$cases | to json
