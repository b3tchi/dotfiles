#!/usr/bin/env nu
# Worker state-machine cases (sp028 T1).
#
# The table in infinifu-worker.nu is the contract, so these cases walk the FULL
# cartesian product of states rather than spot-checking a few edges. An
# enumerated set of "known bad" pairs would only ever catch the edges someone
# already thought of; the product catches the edge a future commit adds by
# accident.

use harness.nu *
use ../../claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu *

let table = (transitions)

# Every edge the table declares must actually be walkable, and every pair it
# does not declare must be refused. Both halves matter: a validator that
# accepts everything and one that refuses everything each satisfy only one.
let product_cases = (
    $WORKER_STATES | each {|from|
        $WORKER_STATES | each {|to|
            let declared = (($table | where from == $from and to == $to | length) > 0)
            run-case $"transition/($from)->($to)" {
                assert-eq (legal-transition? $from $to) $declared "table and predicate must agree"
                if $declared {
                    validate-transition $from $to
                } else {
                    assert-rejects { validate-transition $from $to } "illegal transition" $"($from) -> ($to) is not in the table"
                }
            }
        }
    } | flatten
)

let rule_cases = [
    # ------------------------------------------------------ acceptance gate
    (run-case "transition/only-complete-may-become-accepted" {
        # This is the edge that makes `accepted` mean "reviewed" rather than
        # "the worker said so". Everything else must be refused.
        let sources = ($table | where to == "accepted" | get from)
        assert-eq $sources ["complete"] "exactly one state may transition into accepted"
    })
    (run-case "transition/accepted-is-terminal" {
        assert-eq ($table | where from == "accepted" | length) 0 "accepted has no outgoing edges"
    })
    (run-case "transition/stopped-is-terminal" {
        assert-eq ($table | where from == "stopped" | length) 0 "stopped has no outgoing edges"
    })

    # ------------------------------------------- reportable-status invariant
    (run-case "transition/result-statuses-are-a-subset-of-worker-states" {
        for s in $RESULT_STATUSES {
            assert-true ($s in $WORKER_STATES) $"($s) is reportable but not a persisted state"
        }
    })
    (run-case "transition/no-externally-granted-state-is-self-reportable" {
        # `accepted` is granted by review or a successful merge and `stopped`
        # is an external teardown, so neither may appear in the list a worker
        # reports from. Asserted on the constant, not only on the validator:
        # widening the list is the quiet way this rule would be lost, and the
        # validator's explicit guard would go on masking it.
        for granted in ["accepted" "stopped"] {
            assert-true ($granted not-in $RESULT_STATUSES) $"($granted) is granted externally and must not be self-reportable"
        }
    })
    (run-case "transition/lifecycle-only-states-are-not-reportable" {
        # `created` and `running` describe where a worker is, not an outcome.
        for lifecycle in ["created" "running"] {
            assert-true ($lifecycle not-in $RESULT_STATUSES) $"($lifecycle) is a position, not a result"
        }
    })

    # ------------------------------------------------------------- resumes
    (run-case "transition/resumable-outcomes-return-to-running" {
        # sp028: waiting-human, blocked, failed, complete and protocol_error
        # are all recoverable — a rejected implementation resumes its own Pi
        # session rather than starting a fresh worker.
        for state in ["waiting_human" "blocked" "failed" "complete" "protocol_error"] {
            assert-true (legal-transition? $state "running") $"($state) must be resumable to running"
        }
    })

    # ---------------------------------------------- unknown is not a state
    (run-case "transition/unknown-is-not-a-persisted-state" {
        assert-true ("unknown" not-in $WORKER_STATES) "unknown must not be a persisted state"
    })
    (run-case "transition/unknown-rejected-as-source" {
        assert-rejects { validate-transition "unknown" "stopped" } "observational" "unknown must not license a transition"
    })
    (run-case "transition/unknown-rejected-as-target" {
        assert-rejects { validate-transition "running" "unknown" } "observational" "unknown must not be recorded"
    })
    (run-case "transition/unknown-never-licenses-cleanup" {
        # adr0017: absent evidence is a reason to look again, not to tear down.
        # Both cleanup-shaped edges out of `unknown` must be refused.
        for target in ["stopped" "accepted"] {
            assert-rejects { validate-transition "unknown" $target } "observational" $"unknown must not reach ($target)"
        }
    })

    # -------------------------------------------------- unrecognised states
    (run-case "transition/rejects-unknown-state-name" {
        assert-rejects { validate-transition "running" "finished" } "unknown worker state" "a typo must not behave like a new state"
    })

    # ------------------------------------- settling without the result tool
    (run-case "transition/settling-without-result-is-a-protocol-error" {
        let envelope = (settled-without-result "run-42" "impl-x" 3 "2026-09-05T10:00:00Z")
        validate-envelope $envelope
        assert-eq $envelope.kind "error" "a silent settle produces an error envelope"
        assert-eq $envelope.payload.code "protocol_error" "and never a completion"
        assert-true (legal-transition? "running" "protocol_error") "running must be able to record a protocol error"
    })
    (run-case "transition/created-cannot-report-an-outcome" {
        # A worker that never started has nothing to report; jumping straight
        # to an outcome would mean the outcome was inferred, not observed.
        for outcome in ["complete" "failed" "blocked" "waiting_human" "accepted"] {
            assert-rejects { validate-transition "created" $outcome } "illegal transition" $"created must not report ($outcome)"
        }
    })
]

$product_cases ++ $rule_cases | to json
