#!/usr/bin/env nu
# Message bus cases (sp028 T2).
#
# Every case runs against its own XDG_RUNTIME_DIR, so the suite never touches a
# live session's runtime directory and cases cannot leak state into each other.
#
# The properties under test are the ones a crash or a race would break, not the
# happy path: an envelope is either wholly there or absent, delivery repeats
# until it is acknowledged and stops afterwards, and one run can never read
# another's mail.

use harness.nu *
use ../../claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu *

def sample-result-args []: nothing -> record {
    {
        status: "complete"
        summary: "bus landed"
        validation: "PASS"
        window: "impl-dotfiles-963w.2@dotfiles"
        session: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        resume: "pi --session 0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
    }
}

def put-result [run: string, uid: string, overrides: record = {}]: nothing -> record {
    bus-result $uid --run $run --result ((sample-result-args) | merge $overrides)
}

let cases = [
    # ------------------------------------------------------ addressed round trip
    (run-case "bus/send-then-worker-reads-its-own-inbox" {
        let root = (make-runtime "roundtrip")
        with-runtime $root {
            bus-send "impl-a" --run "run-1" --payload {stage: "work-do", task: "dotfiles-963w.2"}
            let pending = (bus-inbox "impl-a" --run "run-1")
            assert-eq ($pending | length) 1 "the worker sees exactly its own message"
            assert-eq $pending.0.payload.task "dotfiles-963w.2" "payload survives the round trip"
            assert-eq $pending.0.kind "inbox" ""
        }
        rm -rf $root
    })

    (run-case "bus/sequences-are-monotonic-per-worker" {
        let root = (make-runtime "seq")
        with-runtime $root {
            for i in 1..4 { bus-send "impl-a" --run "run-1" --payload {stage: "work-do", task: $"t-($i)"} }
            let seqs = (bus-inbox "impl-a" --run "run-1" | get sequence)
            assert-eq $seqs [1 2 3 4] "sequences increase by one and arrive in order"
        }
        rm -rf $root
    })

    # ------------------------------------------------------------- permissions
    (run-case "bus/runtime-directories-are-0700" {
        let root = (make-runtime "perm-dir")
        with-runtime $root {
            bus-send "impl-a" --run "run-1" --payload {stage: "work-do", task: "t"}
            for dir in [(bus-root) (bus-root | path join "run-1") (bus-root | path join "run-1" "impl-a")] {
                assert-eq (dir-mode-of $dir) "rwx------" $"($dir) must not be readable by other users"
            }
        }
        rm -rf $root
    })

    (run-case "bus/envelope-files-are-0600" {
        let root = (make-runtime "perm-file")
        with-runtime $root {
            bus-send "impl-a" --run "run-1" --payload {stage: "work-do", task: "t"}
            put-result "run-1" "impl-a"
            let files = (glob ((bus-root) + "/run-1/impl-a/**/*.json"))
            assert-true (($files | length) >= 2) "both an inbox and an outbox envelope exist"
            for f in $files { assert-eq (mode-of $f) "rw-------" $"($f) must be private to its owner" }
        }
        rm -rf $root
    })

    # -------------------------------------------------------------- atomicity
    (run-case "bus/no-partial-envelope-is-ever-readable" {
        # Crash injection: a half-written envelope left behind by an interrupted
        # writer must be invisible to every reader. The bus writes to a scratch
        # name and renames, so a partial file cannot carry a live envelope name.
        let root = (make-runtime "partial")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let dir = ((bus-root) | path join "run-1" "impl-a" "outbox")
            "{\"protocol\":1,\"seq" | save -f ($dir | path join "2.json.tmp.crash")

            let pending = (bus-pending "run-1")
            assert-eq ($pending | length) 1 "the interrupted write is not delivered"
            assert-eq $pending.0.sequence 1 "only the completed envelope is visible"
        }
        rm -rf $root
    })

    (run-case "bus/scratch-files-are-not-left-behind-on-success" {
        let root = (make-runtime "scratch")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let leftovers = (glob ((bus-root) + "/**/*.tmp.*"))
            assert-eq $leftovers [] "a successful write leaves no scratch file"
        }
        rm -rf $root
    })

    # ------------------------------------------------- at-least-once delivery
    (run-case "bus/wait-redelivers-until-ack" {
        let root = (make-runtime "redeliver")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let first = (bus-wait --run "run-1")
            let second = (bus-wait --run "run-1")
            assert-eq $first.sequence $second.sequence "wait is non-destructive until acknowledged"
            assert-eq $first.payload.status "complete" ""
        }
        rm -rf $root
    })

    (run-case "bus/wait-stops-after-ack" {
        let root = (make-runtime "ack")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let got = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid "impl-a" --sequence $got.sequence
            assert-true ((bus-wait --run "run-1") | is-empty) "an acknowledged result is not redelivered"
        }
        rm -rf $root
    })

    (run-case "bus/initiator-restart-redelivers-an-unacked-result" {
        # The restart case: the initiator died between reading a completion and
        # acknowledging it. Delivery state lives on disk, not in the reader, so
        # a fresh process must see the same envelope again.
        let root = (make-runtime "restart")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let before = (bus-wait --run "run-1")
            # A brand-new nushell process stands in for the restarted initiator.
            let script = ([$root "restart-probe.nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\nbus-wait --run \"run-1\" | to json" | save -f $script
            let out = (with-env {XDG_RUNTIME_DIR: $root} { ^$nu.current-exe $script } | complete)
            assert-eq $out.exit_code 0 $"restart probe failed: ($out.stderr)"
            let after = ($out.stdout | from json)
            assert-eq $after.sequence $before.sequence "a restarted initiator sees the unacknowledged result"

            bus-ack --run "run-1" --uid "impl-a" --sequence $before.sequence
            let out2 = (with-env {XDG_RUNTIME_DIR: $root} { ^$nu.current-exe $script } | complete)
            assert-eq ($out2.stdout | from json) null "and stops seeing it once acknowledged"
        }
        rm -rf $root
    })

    (run-case "bus/ack-does-not-accept-the-work" {
        # Acknowledgement is a delivery receipt. Treating it as acceptance would
        # let a completion clean up its own worker before anyone reviewed it.
        let root = (make-runtime "ack-meaning")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let got = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid "impl-a" --sequence $got.sequence
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "complete" "ack leaves the worker complete, not accepted"
        }
        rm -rf $root
    })

    # -------------------------------------------------------------- isolation
    (run-case "bus/one-run-cannot-consume-another-runs-envelopes" {
        let root = (make-runtime "isolation")
        with-runtime $root {
            put-result "run-1" "impl-a" {summary: "from run one"}
            put-result "run-2" "impl-b" {summary: "from run two"}

            let one = (bus-wait --run "run-1")
            let two = (bus-wait --run "run-2")
            assert-eq $one.payload.summary "from run one" ""
            assert-eq $two.payload.summary "from run two" ""
            assert-eq $one.uid "impl-a" ""
            assert-eq $two.uid "impl-b" ""

            # Acknowledging one run must not silence the other.
            bus-ack --run "run-1" --uid "impl-a" --sequence $one.sequence
            assert-true ((bus-wait --run "run-2") | is-not-empty) "run-2's mail is untouched"
        }
        rm -rf $root
    })

    (run-case "bus/two-workers-in-one-run-both-report" {
        # Two completions arriving for one run: both must be delivered, oldest
        # first, and neither may mask the other.
        let root = (make-runtime "concurrent")
        with-runtime $root {
            put-result "run-1" "impl-a" {summary: "a done"}
            put-result "run-1" "rev-a" {summary: "b done"}
            let pending = (bus-pending "run-1")
            assert-eq ($pending | length) 2 "both completions are pending"
            assert-eq ($pending | get uid | sort) ["impl-a" "rev-a"] ""

            let first = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid $first.uid --sequence $first.sequence
            let second = (bus-wait --run "run-1")
            assert-true ($second.uid != $first.uid) "the second worker's result is still delivered"
        }
        rm -rf $root
    })

    (run-case "bus/concurrent-writers-never-share-a-sequence" {
        # Sequence allocation must serialise. Two writers racing for the same
        # slot is the interesting case: the loser retries rather than silently
        # overwriting the winner's envelope.
        let root = (make-runtime "race")
        with-runtime $root {
            let script = ([$root "writer.nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\nlet n = \$env.WRITER_N\nfor i in 1..10 { bus-send \"impl-a\" --run \"run-1\" --payload {stage: \"work-do\", task: \$\"t-\(\$n)-\(\$i)\"} }" | save -f $script

            let procs = ([1 2 3] | par-each {|n|
                with-env {XDG_RUNTIME_DIR: $root, WRITER_N: ($n | into string)} {
                    ^$nu.current-exe $script | complete
                }
            })
            for p in $procs { assert-eq $p.exit_code 0 $"writer failed: ($p.stderr)" }

            let inbox = (bus-inbox "impl-a" --run "run-1")
            assert-eq ($inbox | length) 30 "every message survives the race"
            assert-eq ($inbox | get sequence | uniq | length) 30 "no two messages share a sequence"
            assert-eq ($inbox | get payload.task | uniq | length) 30 "no message was overwritten"
        }
        rm -rf $root
    })

    # ------------------------------------------------------------ fail closed
    (run-case "bus/rejects-a-malformed-envelope-on-write" {
        let root = (make-runtime "malformed-write")
        with-runtime $root {
            assert-rejects {
                bus-send "impl-a" --run "run-1" --payload {stage: "work-do", task: "t", design: "copied prose"}
            } "work-do" "a payload violating the protocol never reaches the runtime dir"
            let written = (glob ((bus-root) + "/**/*.json"))
            assert-eq $written [] "nothing was written"
        }
        rm -rf $root
    })

    (run-case "bus/rejects-unparseable-envelope-on-read-without-advancing" {
        # A corrupt envelope must stop the reader loudly. Skipping it would let
        # a completion vanish silently, which is worse than an error.
        let root = (make-runtime "malformed-read")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let dir = ((bus-root) | path join "run-1" "impl-a" "outbox")
            "not json at all" | save -f ($dir | path join "2.json")

            assert-rejects { bus-pending "run-1" } "2.json" "the reader names the file it could not parse"
            assert-true ((ls ($dir | path join "1.json")) | is-not-empty) "the good envelope is left intact"
        }
        rm -rf $root
    })

    (run-case "bus/rejects-a-schema-violating-envelope-on-read" {
        let root = (make-runtime "schema-read")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let dir = ((bus-root) | path join "run-1" "impl-a" "outbox")
            {protocol: 99, sequence: 2, run: "run-1", uid: "impl-a", kind: "result", created: "2026-09-05T10:00:00Z", payload: {}}
            | to json | save -f ($dir | path join "2.json")

            assert-rejects { bus-pending "run-1" } "protocol" "an unknown protocol version fails closed on read"
        }
        rm -rf $root
    })

    (run-case "bus/rejects-a-runtime-directory-owned-by-another-user" {
        # /tmp is world-writable, so an attacker-planted directory is a real
        # shape. Refusing to use a tree we do not own keeps envelopes out of it.
        let root = (make-runtime "foreign")
        with-runtime $root {
            # Let the bus create its own tree — a plain mkdir here would apply
            # the umask and the case would be judging its own 0755 directory.
            bus-send "impl-a" --run "run-1" --payload {stage: "work-do", task: "t"}
            # /proc is root-owned and always present; standing in for a planted tree.
            assert-rejects { bus-assert-owned "/proc" } "owner" "a directory owned by another user is refused"
            bus-assert-owned (bus-root)
        }
        rm -rf $root
    })

    (run-case "bus/rejects-a-loosened-runtime-directory" {
        let root = (make-runtime "loose")
        with-runtime $root {
            bus-send "impl-a" --run "run-1" --payload {stage: "work-do", task: "t"}
            chmod 755 (bus-root)
            assert-rejects { bus-assert-owned (bus-root) } "0700" "a group- or world-readable bus directory is refused"
        }
        rm -rf $root
    })

    (run-case "bus/wait-on-a-missing-runtime-directory-is-empty-not-an-error" {
        # Nothing has run yet is not a failure; it is simply no mail. But it
        # must not create the tree as a side effect of asking.
        let root = (make-runtime "absent")
        with-runtime $root {
            assert-true ((bus-wait --run "run-1") | is-empty) "no mail before anything is sent"
            assert-true (not ((bus-root) | path join "run-1" | path exists)) "asking does not create the run"
        }
        rm -rf $root
    })

    # -------------------------------------------------- completion envelope
    (run-case "bus/wait-returns-a-bounded-completion-envelope" {
        let root = (make-runtime "bounded")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let got = (bus-wait --run "run-1")
            for field in ["status" "validation" "window" "session" "resume"] {
                assert-true ($field in ($got.payload | columns)) $"the completion envelope must carry ($field)"
            }
            assert-eq $got.payload.resume "pi --session 0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0" "the resume command is exact"
            assert-true ((envelope-bytes $got) <= $MAX_ENVELOPE_BYTES) "the delivered envelope respects the cap"
        }
        rm -rf $root
    })

    (run-case "bus/status-reports-a-worker-without-consuming-its-mail" {
        let root = (make-runtime "status")
        with-runtime $root {
            bus-send "impl-a" --run "run-1" --payload {stage: "work-do", task: "t"}
            put-result "run-1" "impl-a" {status: "blocked", validation: null, summary: "needs a decision"}

            let s = (bus-status "impl-a" --run "run-1")
            assert-eq $s.state "blocked" "status reflects the latest reported outcome"
            assert-eq $s.uid "impl-a" ""
            assert-eq $s.run "run-1" ""
            assert-eq $s.unacked 1 "an unacknowledged result is visible in status"
            assert-true ((bus-wait --run "run-1") | is-not-empty) "status did not consume the result"
        }
        rm -rf $root
    })

    (run-case "bus/status-of-an-unknown-worker-is-unknown-not-an-invention" {
        # adr0017: absent evidence reports `unknown`. It must not be turned into
        # a persisted state, and must not license any cleanup.
        let root = (make-runtime "status-unknown")
        with-runtime $root {
            let s = (bus-status "never-existed" --run "run-1")
            assert-eq $s.state "unknown" "a worker with no evidence is unknown"
            assert-true ("unknown" not-in $WORKER_STATES) "and unknown is still not a persisted state"
        }
        rm -rf $root
    })
]

$cases | to json
