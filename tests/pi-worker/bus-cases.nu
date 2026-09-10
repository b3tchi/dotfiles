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
use ../../claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu *

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

# A result now requires the worker to have an identity, because that is where
# its stage gate comes from (T6). In production worker-spawn always records one
# before the process starts, so these cases record one too rather than
# exercising a state that cannot occur.
def put-result [run: string, uid: string, overrides: record = {}]: nothing -> record {
    if (bus-identity-of $uid --run $run) == null {
        bus-identity $uid --run $run --identity {
            role: "impl", cwd: "/tmp/nowhere", branch: $"wk-($uid).0"
            session: $"sid-($uid)", skill: "wk-build", window: $"($uid)@dotfiles"
        }
    }
    bus-result $uid --run $run --result ((sample-result-args) | merge $overrides)
}

# A stand-in for ~/.pi/agent/sessions: one directory per project slug, each
# holding `<timestamp>_<uuid>.jsonl` transcripts.
def fake-sessions [tag: string, layout: record]: nothing -> string {
    let root = ([(fixture-base) $"pi-worker-sessions-($tag)-(random chars --length 6)"] | path join)
    rm -rf $root
    mkdir $root
    for slug in ($layout | columns) {
        let dir = ($root | path join $slug)
        mkdir $dir
        for f in ($layout | get $slug) { "{}\n" | save -f ($dir | path join $f) }
    }
    $root
}

# ------------------------------------------------- send/queue helpers (sp028 T3/T4)
#
# T3 landed with test-local stand-ins for "a reader" here, since T4's
# queue-rows/bus-wait did not exist yet. T4 (this task) is the real thing, so
# the stand-ins are gone: `unread-rows` and `deliverable-mail` below are now
# thin wrappers over the production `queue-rows`/`bus-wait`, kept only
# because a handful of T3's own cases read more clearly through them.
def unread-rows [uid: string]: nothing -> list<record> {
    queue-rows $uid | where {|row| not $row.read }
}

def deliverable-mail [uid: string]: nothing -> list<record> {
    bus-wait --as $uid
}

let cases = [
    # ------------------------------------------------------ addressed round trip
    (run-case "bus/send-then-worker-reads-its-own-inbox" {
        let root = (make-runtime "roundtrip")
        with-runtime $root {
            legacy-inbox-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "dotfiles-963w.2"}
            let pending = (bus-inbox "impl-a" --run "run-1")
            assert-eq ($pending | length) 1 "the worker sees exactly its own message"
            assert-eq $pending.0.payload.task "dotfiles-963w.2" "payload survives the round trip"
            assert-eq $pending.0.kind "inbox" ""
        }
        rm -rf $root
    })

    (run-case "legacy/sequences-are-monotonic-per-worker" {
        # sp029 T3: `legacy-inbox-send`'s own sequence numbering (dotfiles-
        # v1zt tracks its removal once T5/T6 land) — the new peer-addressed
        # `bus-send` mints an unordered-across-processes id instead; see
        # schema-cases.nu's `mint-msg-id` property cases for that guarantee.
        let root = (make-runtime "seq")
        with-runtime $root {
            for i in 1..4 { legacy-inbox-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: $"t-($i)"} }
            let seqs = (bus-inbox "impl-a" --run "run-1" | get sequence)
            assert-eq $seqs [1 2 3 4] "sequences increase by one and arrive in order"
        }
        rm -rf $root
    })

    # ------------------------------------------------------------- permissions
    (run-case "bus/runtime-directories-are-0700" {
        let root = (make-runtime "perm-dir")
        with-runtime $root {
            legacy-inbox-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
            for dir in [(bus-root) (bus-root | path join "run-1") (bus-root | path join "run-1" "impl-a")] {
                assert-eq (dir-mode-of $dir) "rwx------" $"($dir) must not be readable by other users"
            }
        }
        rm -rf $root
    })

    (run-case "bus/envelope-files-are-0600" {
        let root = (make-runtime "perm-file")
        with-runtime $root {
            legacy-inbox-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
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

            let pending = (legacy-bus-pending "run-1")
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
    #
    # sp029 T4: this whole section exercises the LEGACY run/uid, ack-file
    # result path (legacy-bus-wait/legacy-bus-pending/legacy-bus-ack), which
    # bus-status and the main wait/main ack CLI verbs still depend on
    # (dotfiles-hp6v tracks its retirement). The new project/queue-addressed
    # `bus-wait` has its own "wait/*" section further down, with its own
    # at-least-once story: no ack file, a row is marked in place instead.
    (run-case "bus/wait-redelivers-until-ack" {
        let root = (make-runtime "redeliver")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let first = (legacy-bus-wait --run "run-1")
            let second = (legacy-bus-wait --run "run-1")
            assert-eq $first.sequence $second.sequence "wait is non-destructive until acknowledged"
            assert-eq $first.payload.status "complete" ""
        }
        rm -rf $root
    })

    (run-case "bus/wait-stops-after-ack" {
        let root = (make-runtime "ack")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let got = (legacy-bus-wait --run "run-1")
            legacy-bus-ack --run "run-1" --uid "impl-a" --sequence $got.sequence
            assert-true ((legacy-bus-wait --run "run-1") | is-empty) "an acknowledged result is not redelivered"
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
            let before = (legacy-bus-wait --run "run-1")
            # A brand-new nushell process stands in for the restarted initiator.
            let script = ([$root "restart-probe.nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\nlegacy-bus-wait --run \"run-1\" | to json" | save -f $script
            let out = (with-env {XDG_RUNTIME_DIR: $root} { ^$nu.current-exe $script } | complete)
            assert-eq $out.exit_code 0 $"restart probe failed: ($out.stderr)"
            let after = ($out.stdout | from json)
            assert-eq $after.sequence $before.sequence "a restarted initiator sees the unacknowledged result"

            legacy-bus-ack --run "run-1" --uid "impl-a" --sequence $before.sequence
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
            let got = (legacy-bus-wait --run "run-1")
            legacy-bus-ack --run "run-1" --uid "impl-a" --sequence $got.sequence
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

            let one = (legacy-bus-wait --run "run-1")
            let two = (legacy-bus-wait --run "run-2")
            assert-eq $one.payload.summary "from run one" ""
            assert-eq $two.payload.summary "from run two" ""
            assert-eq $one.uid "impl-a" ""
            assert-eq $two.uid "impl-b" ""

            # Acknowledging one run must not silence the other.
            legacy-bus-ack --run "run-1" --uid "impl-a" --sequence $one.sequence
            assert-true ((legacy-bus-wait --run "run-2") | is-not-empty) "run-2's mail is untouched"
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
            let pending = (legacy-bus-pending "run-1")
            assert-eq ($pending | length) 2 "both completions are pending"
            assert-eq ($pending | get uid | sort) ["impl-a" "rev-a"] ""

            let first = (legacy-bus-wait --run "run-1")
            legacy-bus-ack --run "run-1" --uid $first.uid --sequence $first.sequence
            let second = (legacy-bus-wait --run "run-1")
            assert-true ($second.uid != $first.uid) "the second worker's result is still delivered"
        }
        rm -rf $root
    })

    (run-case "legacy/concurrent-writers-never-share-a-sequence" {
        # sp029 T3: this is the no-gap SEQUENCE invariant, and it is retired
        # for the NEW peer-addressed path — `bus-send` has no sequence to
        # contend for; see "send/concurrent-senders-produce-well-formed-
        # non-interleaved-rows" below for that path's own concurrency proof
        # (fixed-width rows, no interleaving, no shared ids). What remains
        # here is real regression coverage for `legacy-inbox-send`, which
        # still uses `claim-slot`'s sequence-claiming for `worker-resume` and
        # the `main send` CLI verb — tracked for removal as dotfiles-v1zt,
        # pending T5/T6.
        #
        # Sequence allocation must serialise. Two writers racing for the same
        # slot is the interesting case: the loser retries rather than silently
        # overwriting the winner's envelope.
        let root = (make-runtime "race")
        with-runtime $root {
            let script = ([$root "writer.nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\nlet n = \$env.WRITER_N\nfor i in 1..10 { legacy-inbox-send \"impl-a\" --run \"run-1\" --payload {stage: \"wk-build\", task: \$\"t-\(\$n)-\(\$i)\"} }" | save -f $script

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
    #
    # sp029 T2: the stage/ticket shape check this case used to exercise is
    # retired — a bus that cannot interpret `content` cannot gate its shape,
    # so `{stage: "wk-build", task: "t", design: "copied prose"}` is now a
    # legal (if opaque) message body. What the bus still owns is the size
    # cap, so that is what "fail closed on write" now asserts here.
    (run-case "bus/rejects-an-oversized-payload-on-write" {
        let root = (make-runtime "malformed-write")
        with-runtime $root {
            let huge = ("x" | fill --width 70000 --character "x")
            assert-rejects {
                legacy-inbox-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: $huge}
            } "64 KiB" "content violating the size cap never reaches the runtime dir"
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

            assert-rejects { legacy-bus-pending "run-1" } "2.json" "the reader names the file it could not parse"
            assert-true ((ls ($dir | path join "1.json")) | is-not-empty) "the good envelope is left intact"
        }
        rm -rf $root
    })

    (run-case "bus/rejects-a-schema-violating-envelope-on-read" {
        let root = (make-runtime "schema-read")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let dir = ((bus-root) | path join "run-1" "impl-a" "outbox")
            {
                protocol: 99, sequence: 2, run: "run-1", uid: "impl-a", kind: "result"
                created: "2026-09-05T10:00:00Z", from: "impl-a", to: ["run-1"], content: {}, payload: {}
            }
            | to json | save -f ($dir | path join "2.json")

            assert-rejects { legacy-bus-pending "run-1" } "protocol" "an unknown protocol version fails closed on read"
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
            legacy-inbox-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
            # /proc is root-owned and always present; standing in for a planted tree.
            assert-rejects { bus-assert-owned "/proc" } "owner" "a directory owned by another user is refused"
            bus-assert-owned (bus-root)
        }
        rm -rf $root
    })

    (run-case "bus/rejects-a-loosened-runtime-directory" {
        let root = (make-runtime "loose")
        with-runtime $root {
            legacy-inbox-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
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
            assert-true ((legacy-bus-wait --run "run-1") | is-empty) "no mail before anything is sent"
            assert-true (not ((bus-root) | path join "run-1" | path exists)) "asking does not create the run"
        }
        rm -rf $root
    })

    # -------------------------------------------------- completion envelope
    (run-case "bus/wait-returns-a-bounded-completion-envelope" {
        let root = (make-runtime "bounded")
        with-runtime $root {
            put-result "run-1" "impl-a"
            let got = (legacy-bus-wait --run "run-1")
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
            legacy-inbox-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
            put-result "run-1" "impl-a" {status: "blocked", validation: null, summary: "needs a decision"}

            let s = (bus-status "impl-a" --run "run-1")
            assert-eq $s.state "blocked" "status reflects the latest reported outcome"
            assert-eq $s.uid "impl-a" ""
            assert-eq $s.run "run-1" ""
            assert-eq $s.unacked 1 "an unacknowledged result is visible in status"
            assert-true ((legacy-bus-wait --run "run-1") | is-not-empty) "status did not consume the result"
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
    (run-case "bus/a-settled-worker-reports-state-protocol-error-not-a-crash" {
        # `protocol_error` was already a declared WORKER_STATE, but bus-status
        # derived state as `results | last | get payload.status` — which only
        # exists on a RESULT payload. No error envelope was ever written before
        # dotfiles-87bt, so the reader never met one; the first real settle
        # crashed it with "column 'status' is missing". The envelope's KIND is
        # what says which shape its payload has.
        let root = (make-runtime "settled-state")
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "wk-t1.0"
                session: "sid-1", skill: "wk-build", window: "impl-a@dotfiles"
                commissioner: "r1"
            }
            bus-settled "impl-a" --run "r1"

            let status = (bus-status "impl-a" --run "r1")
            assert-eq $status.state "protocol_error" "a silent settle is a protocol error, not a crash"
            assert-eq $status.results 1 "and it counts as an outcome"
            assert-eq $status.unacked 1 "the initiator has not seen it yet"
        }
        rm -rf $root
    })

    # ------------------------------------------- settling without a result
    #
    # dotfiles-87bt: a worker that finishes its turn without reporting used to
    # produce SILENCE — state stayed `running`, `wait` returned nothing, and an
    # initiator could not tell "still working" from "gave up". The absence of a
    # result is itself the report.

    (run-case "bus/a-settle-with-no-result-is-reported-as-a-protocol-error" {
        let root = (make-runtime "settled-none")
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "wk-t1.0"
                session: "sid-1", skill: "wk-build", window: "impl-a@dotfiles"
                commissioner: "r1"
            }

            let written = (bus-settled "impl-a" --run "r1")
            assert-true $written.reported "a settle with nothing to show must be reported"

            # read-results yields payloads; the envelope kind is read off disk
            # so the test proves an `error` envelope was written, not a
            # `result` one carrying an error-shaped payload.
            let results = (read-results "impl-a" --run "r1")
            assert-eq ($results | length) 1 "exactly one outcome"
            let payload = ($results | first)
            assert-eq $payload.code "protocol_error" "with the protocol_error code"
            assert-true ($payload.detail | str contains "never inferred") "carrying the reason"

            let file = (ls ($env.XDG_RUNTIME_DIR | path join "pi-worker" "r1" "impl-a" "outbox") | where name =~ '\.json$' | first | get name)
            assert-eq (open $file | get kind) "error" "it is an error envelope, not a result"
        }
        rm -rf $root
    })

    (run-case "bus/a-settle-after-a-real-result-reports-nothing" {
        # The normal path: the worker called the tool, THEN its turn settled.
        # Emitting a protocol error here would turn every successful worker
        # into a failed one.
        let root = (make-runtime "settled-after")
        with-runtime $root {
            # commissioner recorded explicitly (not via put-result's shared
            # default identity), so this exercises the "already reported"
            # branch of bus-settled specifically, rather than passing
            # vacuously because nobody commissioned this worker either way.
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "wk-t1.0"
                session: "sid-impl-a", skill: "wk-build", window: "impl-a@dotfiles"
                commissioner: "r1"
            }
            put-result "r1" "impl-a"
            let written = (bus-settled "impl-a" --run "r1")

            assert-true (not $written.reported) "a reported worker settles quietly"
            assert-eq ((read-results "impl-a" --run "r1") | length) 1 "and nothing is appended"
        }
        rm -rf $root
    })

    (run-case "bus/settling-twice-does-not-stack-protocol-errors" {
        # agent_settled can fire more than once in a session's life. One
        # unanswered turn is one protocol error, not one per settle.
        let root = (make-runtime "settled-twice")
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "wk-t1.0"
                session: "sid-1", skill: "wk-build", window: "impl-a@dotfiles"
                commissioner: "r1"
            }
            bus-settled "impl-a" --run "r1"
            let second = (bus-settled "impl-a" --run "r1")

            assert-true (not $second.reported) "the second settle adds nothing"
            assert-eq ((read-results "impl-a" --run "r1") | length) 1 "still one envelope"
        }
        rm -rf $root
    })


    # ------------------------------------------------- resume after cleanup
    #
    # dotfiles-lr2w: every result envelope carries `resume: pi --session <id>`,
    # and the README promised that command still works after `accept`. It does
    # not. Pi binds a session to the directory it was created in and refuses to
    # start when that directory is gone:
    #
    #   Stored session working directory does not exist: .../wk-t1.0
    #
    # Naming the session FILE instead of the id does not help — same refusal.
    # The transcript is not lost, but the documented command cannot reach it;
    # `pi --fork <file>` can, from any valid directory.
    #
    # So the hint has to be time-aware: correct while the worktree stands,
    # correct once it is gone. Nothing is stored to achieve that — the honest
    # answer is derived when asked.

    (run-case "bus/the-transcript-is-located-by-session-id" {
        let sessions = (fake-sessions "found" {
            "--tmp-wt--": ["2026-09-06T10-00-00-000Z_aaaa1111-2222-3333-4444-555566667777.jsonl"]
        })
        let found = (pi-session-file "aaaa1111-2222-3333-4444-555566667777" --sessions-dir $sessions)
        assert-true ($found | str ends-with "_aaaa1111-2222-3333-4444-555566667777.jsonl") $"got ($found)"
        rm -rf $sessions
    })

    (run-case "bus/an-absent-transcript-is-null-not-a-guess" {
        # A path we invented would send an operator to a file that is not there.
        let sessions = (fake-sessions "missing" {})
        assert-eq (pi-session-file "aaaa1111-2222-3333-4444-555566667777" --sessions-dir $sessions) null "no transcript, no claim"
        rm -rf $sessions
    })

    (run-case "bus/resume-is-a-plain-resume-while-the-worktree-stands" {
        let root = (make-runtime "resume-live")
        let repo = (make-repo "resume-live")
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: $repo, branch: "wk-t1.0"
                session: "aaaa1111-2222-3333-4444-555566667777", skill: "wk-build", window: "impl-a@dotfiles"
            }
            let seen = (worker-inspect "impl-a" --run "r1")
            assert-eq $seen.resume "pi --session aaaa1111-2222-3333-4444-555566667777" "the ordinary case is unchanged"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "bus/resume-becomes-a-fork-once-the-worktree-is-gone" {
        # After `accept`, `pi --session <id>` cannot start. Handing an operator
        # a command that refuses is worse than handing them none.
        let root = (make-runtime "resume-gone")
        let sessions = (fake-sessions "gone" {
            "--tmp-wt--": ["2026-09-06T10-00-00-000Z_aaaa1111-2222-3333-4444-555566667777.jsonl"]
        })
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/nonexistent/wk-t1.0", branch: "wk-t1.0"
                session: "aaaa1111-2222-3333-4444-555566667777", skill: "wk-build", window: "impl-a@dotfiles"
            }
            let seen = (worker-inspect "impl-a" --run "r1" --sessions-dir $sessions)

            assert-true ($seen.resume | str starts-with "pi --fork ") $"a fork is the only thing that works, got ($seen.resume)"
            assert-true ($seen.resume | str contains "aaaa1111") "naming the right transcript"
            assert-true ($seen.transcript | str ends-with ".jsonl") "and the file itself is reported"
        }
        rm -rf $root; rm -rf $sessions
    })

    (run-case "bus/a-vanished-worktree-with-no-transcript-says-so-plainly" {
        # Both gone: report the loss rather than a command that cannot work.
        let root = (make-runtime "resume-none")
        let sessions = (fake-sessions "none" {})
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/nonexistent/wk-t1.0", branch: "wk-t1.0"
                session: "aaaa1111-2222-3333-4444-555566667777", skill: "wk-build", window: "impl-a@dotfiles"
            }
            let seen = (worker-inspect "impl-a" --run "r1" --sessions-dir $sessions)
            assert-eq $seen.transcript null "no transcript found"
            assert-true ($seen.resume | str contains "no longer exists") $"say what happened, got ($seen.resume)"
        }
        rm -rf $root; rm -rf $sessions
    })


    (run-case "bus/the-roster-lists-every-worker-across-every-run" {
        # "Which agents are running and where do I find them?" is the question
        # an operator actually asks, and answering it used to mean knowing the
        # run id first. The roster spans runs and carries only what locating a
        # worker needs.
        let root = (make-runtime "roster")
        with-runtime $root {
            for pair in [["r1" "a"] ["r1" "b"] ["r2" "c"]] {
                bus-identity ($pair | get 1) --run ($pair | get 0) --identity {
                    # A real directory, so the resume hint is the plain form;
                    # the vanished-worktree case is covered separately.
                    role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                    session: $"sid-($pair | get 1)", skill: "wk-build"
                    window: $"impl-($pair | get 1)@dotfiles"
                    window_id: $"@($pair | get 1)"
                }
            }
            let roster = (worker-roster)
            assert-eq ($roster | length) 3 "every worker in every run"
            assert-eq ($roster | get run | uniq | sort) ["r1" "r2"] "spanning both runs"

            let one = ($roster | where uid == "c" | first)
            assert-eq $one.run "r2" ""
            assert-eq $one.window "impl-c@dotfiles" "where to look for it"
            # The frame wears this as a suffix on the address — `r2/c@c` — so a
            # row carries one name instead of two, and the operator can still
            # `select-window -t` what it names.
            assert-eq $one.window_id "@c" "the window id to jump to"
            # Absent, not invented, for an identity written before the id was
            # recorded: the frame renders a bare address for those.
            bus-identity "old" --run "r3" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                session: "sid-old", skill: "wk-build", window: "impl-old@dotfiles"
            }
            assert-eq ((worker-roster --run "r3") | first | get window_id) "" "no id recorded, no id reported"
            assert-eq $one.resume "pi --session sid-c" "how to get into its transcript"
            assert-true ("liveness" in ($one | columns)) "and whether it is actually running"

            # Scoped when asked.
            assert-eq ((worker-roster --run "r1") | length) 2 "a single run can still be asked for"
        }
        rm -rf $root
    })

    (run-case "bus/a-main-isolation-worker-cannot-commit-to-the-operators-tree" {
        # Six worker commits reached this repo's own main in one evening, five
        # files of them tracked and pushed, because a stage with
        # isolation: main puts the worker in the operator's checkout on their
        # branch and nothing stopped it doing what a coding agent does.
        #
        # Guidance was not going to hold it — a worker that decides committing
        # is helpful will commit — so git enforces it, and this asserts that
        # git actually does.
        let root = (make-runtime "commit-guard")
        let repo = ([(fixture-base) $"piw-guard-(random chars --length 6)"] | path join)
        rm -rf $repo; mkdir $repo
        ^git -C $repo init -q
        ^git -C $repo config user.email "t@t"; ^git -C $repo config user.name "t"
        "x\n" | save -f ($repo | path join "f.txt")
        ^git -C $repo add f.txt

        with-runtime $root {
            let hooks = (write-commit-guard "r1" "w1" "probe" "main")

            # Exactly what spawn puts in a main-isolation worker's window.
            let refused = (with-env {
                GIT_CONFIG_COUNT: "1"
                GIT_CONFIG_KEY_0: "core.hooksPath"
                GIT_CONFIG_VALUE_0: $hooks
            } { do { ^git -C $repo commit -m "worker commit" } | complete })

            assert-true ($refused.exit_code != 0) "the commit is refused"
            assert-true ($refused.stderr | str contains "operator's own working tree") "and says why"
            assert-true ($refused.stderr | str contains "isolation: worktree") "and what would work instead"
            assert-eq (^git -C $repo log --oneline | complete | get exit_code) 128 "nothing was committed"

            # The operator, with no such environment, is untouched.
            let allowed = (do { ^git -C $repo commit -m "operator commit" } | complete)
            assert-eq $allowed.exit_code 0 $"the operator can still commit: ($allowed.stderr)"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "bus/the-timeline-and-the-status-cannot-disagree" {
        # The reason derive-state was extracted rather than reimplemented. The
        # frame shows a worker's state; the timeline shows the state after each
        # event. Two copies of the precedence table would be two answers to
        # "what is this worker" the first time someone edited one, and the
        # whole value of putting them side by side is that they agree.
        #
        # This walks a worker through the interesting transitions and asserts
        # the invariant after each: the LAST state in the timeline is the state
        # `status` reports.
        let root = (make-runtime "timeline-agrees")
        with-runtime $root {
            bus-identity "w1" --run "r1" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                # `doc-draft` from the fixture registry: an instructions stage
                # in the main worktree, so neither the payload shape nor the
                # commit gate is what this case is testing.
                session: "s", skill: "doc-draft", window: "w1@dotfiles"
            }
            let agrees = {||
                let tl = (worker-timeline "w1" --run "r1")
                let last = (if ($tl | is-empty) { "none" } else { $tl | last | get state })
                assert-eq $last (bus-status "w1" --run "r1" | get state) "timeline's last state is the status"
            }

            do $agrees   # created
            legacy-inbox-send "w1" --run "r1" --payload {stage: "doc-draft", instructions: "do the thing"}
            do $agrees   # still created: being sent work is not reporting

            bus-result "w1" --run "r1" --result {
                status: "complete", summary: "did it", window: "w1@dotfiles"
                session: "s", resume: "pi --session s", validation: "checked"
            }
            do $agrees   # complete

            # Rejected and sent back: the newest result still says complete, so
            # only the marker's precedence gets this right.
            #
            # The marker file is written directly because the only writer is
            # inside worker-resume, which needs a live tmux server — and this
            # case is about the derivation, not about tmux.
            "1" | save -f (bus-root | path join "r1" "w1" "reopened.marker")
            do $agrees   # running

            bus-result "w1" --run "r1" --result {
                status: "blocked", summary: "stuck", window: "w1@dotfiles"
                session: "s", resume: "pi --session s", validation: "n/a"
            }
            do $agrees   # blocked: the newer sequence outranks the marker
        }
        rm -rf $root
    })

    (run-case "bus/an-address-is-minted-when-none-is-given" {
        # An agent that must supply a uid and has no way to make one shells out
        # to `uuidgen`, which lands a bare 36-character id in the operator's
        # transcript for no reason. Minting it here removes the need, and a
        # `<role>-<n>` id is legible in a window name and in the frame, which a
        # uuid is not.
        let root = (make-runtime "mint-uid")
        let repo = (make-repo "mint-uid")
        with-runtime $root {
            assert-eq (mint-uid "impl" $repo) "impl-1" "the first of a role"
            bus-identity "impl-1" --run "r1" --identity {
                role: "impl", cwd: $repo, branch: "wk-t.0"
                session: "s", skill: "wk-build", window: "impl-1@dotfiles"
            }
            assert-eq (mint-uid "impl" $repo) "impl-2" "the next one skips the taken address"
            assert-eq (mint-uid "rev" $repo) "rev-1" "counted per role"
        }
        rm -rf $repo
        rm -rf $root
    })

    (run-case "bus/an-address-minted-for-a-fresh-run-does-not-collide-with-a-live-one" {
        # dotfiles-bg65, reproduced. `mint-uid` scoped its search to ONE run's
        # directory, which made sense while `--run` was a caller-supplied
        # grouping several workers shared. sp029 T9 retired `--run`: every
        # spawn now mints its own run (`next-run-id`, unconditional), so the
        # directory `mint-uid` searched was empty BY CONSTRUCTION and two
        # ordinary same-role spawns both minted `<role>-1`.
        #
        # That is not a cosmetic clash. The peer bus addresses agents by bare
        # uid, project-wide (`bus/queue/<uid>`), and `resolve-run` picks
        # whichever run sorts first, so every uid-addressed verb (`stop`, `rm`,
        # `status`, `resume`, `accept`) could only ever reach ONE of the two —
        # the other stayed live with no CLI address at all. Observed live in
        # the sp029 T11 smoke, which had to tear the loser down with `rm -rf`.
        let root = (make-runtime "mint-collide")
        let repo = (make-repo "mint-collide")
        with-runtime $root {
            # Spawn A: its own fresh run, no --uid.
            let run_a = (next-run-id)
            let uid_a = (mint-uid "peer" $repo)
            bus-identity $uid_a --run $run_a --identity {
                role: "peer", cwd: $repo, branch: "wk-a.0"
                session: "sid-a", skill: "wk-build", window: "peer-a@dotfiles"
            }
            # Spawn B: the very next ordinary spawn, and so a fresh run again.
            let run_b = (next-run-id)
            let uid_b = (mint-uid "peer" $repo)
            assert-true ($run_a != $run_b) "the fixture really is two separate runs"
            assert-true ($uid_a != $uid_b) $"two spawns of one role must not share an address \(($uid_a) vs ($uid_b))"
            assert-eq $uid_b "peer-2" "the second one counts past the first, whatever run it was filed under"
        }
        rm -rf $repo
        rm -rf $root
    })

    (run-case "bus/addresses-are-unique-per-project-not-globally" {
        # Uniqueness is scoped exactly where addressing is scoped: `resolve-run`
        # searches ONE project's agents, and sp029's `## solution` makes
        # cross-project addressing structurally impossible. Two projects
        # therefore both start at `impl-1`, and neither can see the other's.
        let root = (make-runtime "mint-scope")
        let a = (make-repo "mint-scope-a")
        let b = (make-repo "mint-scope-b")
        with-runtime $root {
            assert-eq (mint-uid "impl" $a) "impl-1" "the first of a role in project a"
            bus-identity "impl-1" --run "r1" --identity {
                role: "impl", cwd: $a, branch: "wk-t.0"
                session: "s", skill: "wk-build", window: "impl-1@a"
            }
            assert-eq (mint-uid "impl" $a) "impl-2" "taken in project a"
            assert-eq (mint-uid "impl" $b) "impl-1" "and free in project b"
        }
        rm -rf $a
        rm -rf $b
        rm -rf $root
    })

    (run-case "bus/a-worker-in-a-wk-worktree-mints-in-its-main-worktrees-project" {
        # A worker stands in a throwaway `wk-*` tree. Slugging that path
        # directly would make every worker its own project — the discovery
        # failure sp029 T1 exists to fix — and would put uid uniqueness back
        # where it started, one empty directory per spawn.
        let root = (make-runtime "mint-wk")
        let repo = (make-repo "mint-wk")
        with-runtime $root {
            let tree = (worker-placement --repo $repo --isolation "worktree" --subject "t1")
            bus-identity "impl-1" --run "r1" --identity {
                role: "impl", cwd: $tree.path, branch: $tree.branch
                session: "s", skill: "wk-build", window: "impl-1@dotfiles"
            }
            assert-eq (mint-uid "impl" $tree.path) "impl-2" "the worktree resolves to the repo's own project"
            assert-eq (mint-uid "impl" $repo) "impl-2" "and the repo agrees with it"
        }
        rm -rf $repo
        rm -rf $root
    })

    (run-case "bus/a-released-address-is-free-to-mint-again" {
        # `rm` is the documented way to recycle an address ("An address is
        # claimed once: to reuse a uid after stopping or accepting it, call
        # `rm`"). Once uniqueness is project-wide, that promise has to be kept
        # project-wide too: releasing has to let go of the durable placement
        # record, or the address is claimed forever and the message is a lie.
        let root = (make-runtime "mint-release")
        let repo = (make-repo "mint-release")
        with-runtime $root {
            let uid = (mint-uid "impl" $repo)
            bus-identity $uid --run "r1" --identity {
                role: "impl", cwd: $repo, branch: "wk-t.0"
                session: "s", skill: "wk-build", window: $"($uid)@dotfiles"
            }
            assert-eq (mint-uid "impl" $repo) "impl-2" "claimed while it is in use"
            worker-stop $uid --run "r1"
            let released = (worker-release --run "r1" --uid $uid)
            assert-true $released.removed "the address is freed"
            assert-eq (mint-uid "impl" $repo) "impl-1" "and mintable again afterwards"
        }
        rm -rf $repo
        rm -rf $root
    })

    (run-case "bus/an-accepted-workers-address-is-released-once-its-worktree-is-gone" {
        # The path that matters, and the one the first cut of this fix got
        # wrong. `accept` DELETES the worktree an identity names
        # (`worktree-cleanup --path $identity.cwd --accepted`), so by the time
        # the normal accept-then-`rm` sequence runs — the only sequence
        # plan-scrum-master uses — that path is gone. Re-slugging it lands in
        # `resolve-project-slug`'s fallback bucket, which holds none of this
        # worker's records, so release frees nothing and the address plus its
        # queue stay reserved forever. The durable `.index` pointer is what
        # keys the records, and it is what release must resolve from.
        let root = (make-runtime "release-gone")
        let repo = (make-repo "release-gone")
        with-runtime $root {
            let tree = (worker-placement --repo $repo --isolation "worktree" --subject "t1")
            let uid = (mint-uid "impl" $repo)
            bus-identity $uid --run "r1" --identity {
                role: "impl", cwd: $tree.path, branch: $tree.branch
                session: "s", skill: "wk-build", window: $"($uid)@dotfiles"
            }
            # A queue of its own, planted the way a sender makes one — from
            # inside the project, so it lands under the project's real slug.
            let queue = (do {
                cd $repo
                ensure-bus-dirs
                queue-append $uid (mint-msg-id)
                project-dir | path join "queue" $uid
            })
            assert-true ($queue | path exists) "the fixture really planted a queue"

            worker-stop $uid --run "r1"
            # What `accept` does to the tree, without needing a live tmux
            # server to get there.
            ^git -C $repo worktree remove --force $tree.path
            assert-true (not ($tree.path | path exists)) "the worktree is gone, exactly as after accept"

            let released = (worker-release --run "r1" --uid $uid)
            assert-true $released.removed "the address is freed"
            assert-true (not ($queue | path exists)) "its queue goes with it"
            assert-eq (mint-uid "impl" $repo) $uid "and the address is mintable again"
        }
        rm -rf $repo
        rm -rf $root
    })

    (run-case "bus/an-address-is-released-even-after-the-runtime-tree-is-wiped" {
        # `$XDG_RUNTIME_DIR` is wiped at logout by design — that is why the
        # placement record lives under `state-root` at all (sp029 T6). Deciding
        # "is there such a worker" from the runtime tree alone made `rm` a
        # silent no-op after every logout: it answered "no such worker" while
        # the durable record, and so the address, was still there.
        let root = (make-runtime "release-wiped")
        let repo = (make-repo "release-wiped")
        with-runtime $root {
            let uid = (mint-uid "impl" $repo)
            bus-identity $uid --run "r1" --identity {
                role: "impl", cwd: $repo, branch: "wk-t.0"
                session: "s", skill: "wk-build", window: $"($uid)@dotfiles"
            }
            worker-stop $uid --run "r1"
            # The wipe itself: the runtime tree goes, the placement record does
            # not.
            rm -rf (bus-root)
            assert-eq (mint-uid "impl" $repo) "impl-2" "the surviving record still holds the address"

            let released = (worker-release --run "r1" --uid $uid)
            assert-true $released.removed "rm reaches it anyway"
            assert-eq $released.state "stopped" "on the verdict that survived the wipe"
            assert-eq (mint-uid "impl" $repo) $uid "and the address is free again"

            # A uid with no records anywhere is still not a worker.
            let missing = (worker-release --run "r1" --uid "nobody")
            assert-eq $missing.removed false "an unknown address is not released"
            assert-eq $missing.reason "no such worker" "and says so plainly"
        }
        rm -rf $repo
        rm -rf $root
    })

    (run-case "bus/an-occupied-address-is-refused-project-wide" {
        # The occupied-address guard used to check the SAME fresh, always-empty
        # run directory `mint-uid` searched, so it could not fire either. It
        # answers for the project now: a uid already recorded under any run is
        # refused, by name, rather than silently becoming a second worker on
        # one queue.
        let root = (make-runtime "claim-occupied")
        let repo = (make-repo "claim-occupied")
        with-runtime $root {
            bus-identity "impl-1" --run "r1" --identity {
                role: "impl", cwd: $repo, branch: "wk-t.0"
                session: "s", skill: "wk-build", window: "impl-1@dotfiles"
            }
            assert-rejects { claim-address $repo "impl-1" } "already" "a recorded address is occupied"
            # The claim itself is atomic: the winner of a race holds it, and the
            # loser is refused rather than both proceeding on one address.
            claim-address $repo "impl-9"
            assert-rejects { claim-address $repo "impl-9" } "already" "a claimed address is occupied"
            assert-eq (mint-uid "impl" $repo) "impl-2" "a claim counts as taken before any identity exists"
            release-address $repo "impl-9"
            claim-address $repo "impl-9" # freed, so claimable again
        }
        rm -rf $repo
        rm -rf $root
    })

    (run-case "bus/racing-claims-cannot-both-win-one-address" {
        # Two spawns starting at the same instant both see the same lowest-free
        # uid — checking and then creating would let both proceed onto one
        # queue, which is the failure this whole guard exists to prevent. The
        # claim is a single `mkdir` without `-p`, so the kernel picks the
        # winner and every loser is refused and re-mints (`main spawn`'s retry
        # loop). Same reasoning as `claim-slot`'s link(2) on a sequence slot.
        let root = (make-runtime "claim-race")
        let repo = (make-repo "claim-race")
        with-runtime $root {
            let script = ([$root "claimer.nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\ntry { claim-address \$env.RACE_REPO \"impl-1\"; print \"won\" } catch { print \"lost\" }" | save -f $script

            let procs = ([1 2 3 4] | par-each {|n|
                with-env {XDG_RUNTIME_DIR: $root, RACE_REPO: $repo} {
                    ^$nu.current-exe $script | complete
                }
            })
            for p in $procs { assert-eq $p.exit_code 0 $"claimer crashed: ($p.stderr)" }
            let outcomes = ($procs | each {|p| $p.stdout | str trim })
            assert-eq ($outcomes | where {|o| $o == "won" } | length) 1 "exactly one racer holds the address"
            assert-eq ($outcomes | where {|o| $o == "lost" } | length) 3 "and every other one is refused"
        }
        rm -rf $repo
        rm -rf $root
    })

    (run-case "bus/a-pi-session-id-is-minted-when-none-is-given" {
        # The `session` tool parameter was documented as "a fresh uuid for the
        # worker's Pi session", so the agent did the only thing it could: it
        # shelled out to `uuidgen` and put 36 characters of noise in the
        # operator's transcript. The id is passed straight to `pi --session-id`
        # to CREATE a session, so nothing about it needs to come from outside.
        assert-true ((mint-session) != (mint-session)) "a fresh one each time"
        assert-eq ((mint-session) | str length) 36 "shaped like the uuid pi expects"
        assert-true ((mint-session) =~ '^[0-9a-f]{8}-[0-9a-f]{4}-') "and actually a uuid"
    })

    (run-case "bus/a-run-is-minted-when-none-is-given" {
        # `mint-run` is retired by sp029 T1 (project scoping replaces run
        # scoping as the bus's address) and renamed to `next-run-id`, but the
        # logic itself is still live production code reached from `main spawn`
        # whenever `--run` is omitted, pending T9's CLI redesign — so it stays
        # covered under its new name rather than only reachable through a CLI
        # round trip.
        let root = (make-runtime "next-run-id")
        with-runtime $root {
            assert-eq (next-run-id) "r1" "the first run of an empty bus"
            legacy-inbox-send "w" --run "r1" --payload {stage: "wk-build", task: "t"}
            assert-eq (next-run-id) "r2" "the next free one"
            # A run whose name is not `r<N>` must not confuse the counter.
            legacy-inbox-send "w" --run "custom" --payload {stage: "wk-build", task: "t"}
            assert-eq (next-run-id) "r2" "names outside the pattern are ignored, not parsed"
        }
        rm -rf $root
    })

    (run-case "bus/wait-can-block-until-a-result-lands" {
        # `wait` peeked and returned nothing, so an agent told to "wait for its
        # typed result" concluded it needed a polling mechanism and read the
        # worker's tmux pane — the one thing the transport boundary forbids as
        # a completion signal. Blocking here is what removes that reason.
        let root = (make-runtime "wait-block")
        with-runtime $root {
            bus-identity "w1" --run "r1" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                session: "s", skill: "wk-build", window: "w1@dotfiles"
            }
            # Write the result from another process a moment from now, so the
            # blocking wait has something to actually wait FOR.
            let script = ($root | path join "late-result.nu")
            # Single-quoted so the record's own double quotes need no escaping.
            let body = ('use ' + (worker-script $env.FILE_PWD) + ' *
sleep 1200ms
bus-result "w1" --run "r1" --result {status: "complete", summary: "done", window: "w1@dotfiles", session: "s", resume: "pi --session s", validation: "checked"}')
            $body | save -f $script
            # Started in the background so the result lands WHILE the wait
            # below is blocking, rather than before it begins.
            job spawn { ^nu $script | ignore }

            let started = (date now)
            let got = (legacy-bus-wait --run "r1" --uid "w1" --block --timeout 10sec)
            let waited = ((date now) - $started)

            assert-true ($got != null) "it came back with the result, not with nothing"
            assert-eq $got.payload.status "complete" "and it is the worker's own report"
            assert-true ($waited > 500ms) "it actually waited rather than peeking once"
            assert-true ($waited < 9sec) "and returned as soon as the result landed"
        }
        rm -rf $root
    })

    (run-case "bus/a-blocking-wait-gives-up-instead-of-hanging-forever" {
        let root = (make-runtime "wait-timeout")
        with-runtime $root {
            legacy-inbox-send "w1" --run "r1" --payload {stage: "wk-build", task: "t"}
            let started = (date now)
            let got = (legacy-bus-wait --run "r1" --uid "w1" --block --timeout 2sec)
            let waited = ((date now) - $started)
            assert-eq $got null "nothing to report is not an error"
            assert-true ($waited >= 2sec) "it honoured the timeout"
            assert-true ($waited < 6sec) "and did not sit there past it"
        }
        rm -rf $root
    })

    (run-case "bus/wait-without-block-still-peeks-and-returns" {
        # Regression guard: scripts rely on `wait` answering immediately.
        let root = (make-runtime "wait-peek")
        with-runtime $root {
            legacy-inbox-send "w1" --run "r1" --payload {stage: "wk-build", task: "t"}
            let started = (date now)
            assert-eq (legacy-bus-wait --run "r1" --uid "w1") null "still nothing pending"
            assert-true (((date now) - $started) < 500ms) "and it did not block to say so"
        }
        rm -rf $root
    })

    (run-case "bus/the-roster-says-when-each-worker-started" {
        # `running` says nothing about whether that is eight seconds or forty
        # minutes, and only one of those is worth interrupting. The stamp comes
        # from the identity envelope, which is written once at spawn — reading
        # only its payload, as the roster used to, throws the stamp away.
        let root = (make-runtime "roster-started")
        with-runtime $root {
            bus-identity "a" --run "r1" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                session: "sid-a", skill: "wk-build", window: "impl-a@dotfiles"
            }
            # A worker that has been addressed but never spawned: `send` creates
            # its directory before anything is recorded about a process.
            legacy-inbox-send "b" --run "r1" --payload {stage: "wk-build", task: "t"}

            let roster = (worker-roster --run "r1")
            let a = ($roster | where uid == "a" | first)
            assert-true (($a.started | into datetime) <= (date now)) "a real stamp, not a placeholder"
            let b = ($roster | where uid == "b" | first)
            assert-eq $b.started "" "an empty cell rather than a guess when nothing was recorded"
        }
        rm -rf $root
    })

    (run-case "bus/the-roster-is-empty-rather-than-failing-when-nothing-runs" {
        let root = (make-runtime "roster-empty")
        with-runtime $root {
            assert-eq (worker-roster) [] "no runs is not an error"
        }
        rm -rf $root
    })


    (run-case "bus/wait-can-be-scoped-to-one-worker" {
        # `wait --run` returns the oldest unacknowledged result ACROSS the run,
        # which is right for an orchestrator draining many workers and wrong for
        # anyone waiting on a particular one. Observed live: a run still held a
        # finished worker with an unacked envelope, so a freshly spawned worker's
        # initiator was handed the previous one's answer — the same stale-state
        # trap as reusing an address.
        let root = (make-runtime "wait-scoped")
        with-runtime $root {
            for u in ["old" "new"] {
                bus-identity $u --run "r1" --identity {
                    role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                    session: $"sid-($u)", skill: "wk-build", window: $"impl-($u)@dotfiles"
                }
            }
            bus-result "old" --run "r1" --result {
                status: "blocked", summary: "stale", window: "w", session: "s", resume: "r"
            }
            bus-result "new" --run "r1" --result {
                status: "complete", summary: "fresh", window: "w", session: "s", resume: "r", validation: "checked"
            }

            # Unscoped keeps its meaning: oldest first, across the run.
            assert-eq (legacy-bus-wait --run "r1" | get uid) "old" "the run-wide wait is unchanged"
            # Scoped answers about the worker asked about.
            assert-eq (legacy-bus-wait --run "r1" --uid "new" | get payload.summary) "fresh" "scoped to the worker"
            assert-eq (legacy-bus-wait --run "r1" --uid "old" | get payload.summary) "stale" ""
        }
        rm -rf $root
    })

    (run-case "bus/a-wait-after-a-sequence-skips-what-the-caller-has-seen" {
        # dotfiles-i0hz. An initiator that gives a reported-but-unacked worker
        # more work had no way to learn when the NEW work was done: `wait`
        # rightly keeps handing over the earlier envelope, because it is
        # unacknowledged and therefore is what is pending — and `ack`, the only
        # thing that clears it, releases the very worker that was supposed to do
        # the follow-up. So the caller says which sequence it has already seen.
        let root = (make-runtime "wait-after")
        with-runtime $root {
            put-result "run-1" "impl-a" {summary: "first round"}

            assert-eq (legacy-bus-wait --run "run-1" --uid "impl-a" --after 1) null "nothing newer than what the caller has seen"
            assert-eq (legacy-bus-wait --run "run-1" --uid "impl-a" | get sequence) 1 "and the earlier envelope is still pending for anyone asking plainly"

            put-result "run-1" "impl-a" {summary: "second round"}
            let newer = (legacy-bus-wait --run "run-1" --uid "impl-a" --after 1)
            assert-eq $newer.sequence 2 "the round the caller had not seen"
            assert-eq $newer.payload.summary "second round" ""
            assert-eq (legacy-bus-wait --run "run-1" --uid "impl-a" | get sequence) 1 "the plain wait is unchanged: oldest unacked first"
        }
        rm -rf $root
    })

    (run-case "bus/wait-after-zero-is-the-same-as-not-asking" {
        # Sequences start at 1, so 0 covers nothing. The default has to behave
        # exactly like the flag's absence or every existing caller changes
        # meaning the day the flag lands.
        let root = (make-runtime "wait-after-zero")
        with-runtime $root {
            put-result "run-1" "impl-a"
            assert-eq (legacy-bus-wait --run "run-1" --uid "impl-a" --after 0 | get sequence) 1 ""
            assert-eq (legacy-bus-wait --run "run-1" --uid "impl-a" | get sequence) 1 ""
        }
        rm -rf $root
    })

    (run-case "bus/wait-after-refuses-to-guess-which-workers-sequence-it-means" {
        # Sequences are per worker: `--after 2` across a run would mean a
        # different thing for each one, and silently skipping another worker's
        # sequence 1 or 2 is exactly the stale-mail bug this flag exists to
        # avoid. So it is refused rather than interpreted.
        let root = (make-runtime "wait-after-unscoped")
        with-runtime $root {
            put-result "run-1" "impl-a"
            assert-rejects {
                legacy-bus-wait --run "run-1" --after 1
            } "per worker" "an unscoped --after has no single meaning"
        }
        rm -rf $root
    })

    (run-case "bus/a-blocking-wait-after-returns-when-the-new-round-lands" {
        # The shape an orchestrator actually uses: hand a worker more work while
        # its previous report is still unacknowledged, then block for the new
        # one.
        let root = (make-runtime "wait-after-block")
        with-runtime $root {
            put-result "run-1" "impl-a" {summary: "first round"}
            let script = ($root | path join "second-round.nu")
            let body = ('use ' + (worker-script $env.FILE_PWD) + ' *
sleep 1200ms
bus-result "impl-a" --run "run-1" --result {status: "complete", summary: "second round", window: "impl-a@dotfiles", session: "sid-impl-a", resume: "pi --session sid-impl-a", validation: "checked"}')
            $body | save -f $script
            job spawn { ^nu $script | ignore }

            let started = (date now)
            let got = (legacy-bus-wait --run "run-1" --uid "impl-a" --after 1 --block --timeout 10sec)
            let waited = ((date now) - $started)

            assert-true ($got != null) "the blocking wait came back with the new round"
            assert-eq $got.sequence 2 ""
            assert-eq $got.payload.summary "second round" ""
            assert-true ($waited > 500ms) "it waited rather than returning the envelope it was told to skip"
        }
        rm -rf $root
    })

    (run-case "bus/a-scoped-wait-on-a-quiet-worker-returns-nothing" {
        let root = (make-runtime "wait-quiet")
        with-runtime $root {
            bus-identity "a" --run "r1" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                session: "sid-a", skill: "wk-build", window: "impl-a@dotfiles"
            }
            assert-eq (legacy-bus-wait --run "r1" --uid "a") null "silence, not someone else's mail"
        }
        rm -rf $root
    })

    (run-case "bus/a-finished-worker-can-be-released-for-reuse" {
        # The occupied-address guard means an address is claimed for the life of
        # the run directory, so repeating a run needs either a new id every time
        # or a way to let one go.
        let root = (make-runtime "release")
        with-runtime $root {
            bus-identity "a" --run "r1" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                session: "sid-a", skill: "wk-build", window: "impl-a@dotfiles"
            }
            # Through the public verb: kill-window tolerates a missing tmux, so
            # this needs no display host.
            worker-stop "a" --run "r1"

            let released = (worker-release --run "r1" --uid "a")
            assert-true $released.removed "the address is freed"
            assert-eq (worker-roster --run "r1") [] "and the worker is gone from the roster"
        }
        rm -rf $root
    })

    (run-case "bus/an-unfinished-worker-is-not-released" {
        # Releasing throws away the only record of what a worker did, so it is
        # refused while anything might still be waiting on it.
        let root = (make-runtime "release-busy")
        with-runtime $root {
            bus-identity "a" --run "r1" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                session: "sid-a", skill: "wk-build", window: "impl-a@dotfiles"
            }
            # `created` since bus-status learned to derive it: this worker was
            # spawned and has never reported. Still unfinished, still refused.
            assert-rejects { worker-release --run "r1" --uid "a" } "created" "a live worker is not discarded"
        }
        rm -rf $root
    })

    # --------------------------------------------------- project scoping (sp029 T1)
    #
    # `project-dir` replaces the run id as the bus's address: a slug of the
    # repo's MAIN worktree, so every agent working on it — from the main
    # worktree or any `wk-*` of it — reaches the same directory without being
    # told an id. `cd` is scoped with `do { }` (nushell restores $env.PWD when
    # the block exits) so a case never leaks its directory into the next one.

    (run-case "project/main-and-a-linked-worktree-share-one-project-dir" {
        let repo = (make-repo "proj-shared")
        let root = (make-runtime "proj-shared")
        with-runtime $root {
            let wk = (worktree-allocate --repo $repo --task "t1")
            let from_main = (do { cd $repo; project-dir })
            let from_wk = (do { cd $wk.path; project-dir })
            assert-eq $from_main $from_wk "a worker in a wk-* worktree addresses the same project as the main worktree"
            assert-true ($from_main | str starts-with $root) "still rooted at this test's own XDG_RUNTIME_DIR"
            assert-true ($from_main | str ends-with "/bus") "project-dir names the bus subtree specifically"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "project/similar-paths-slug-to-different-projects" {
        # `/a/b` and `/a-b` must not collide: a path separator and a literal
        # hyphen both flatten to `-` under a naive sanitizer, which is exactly
        # the bug a prefix-only slug would have.
        let base = ([(fixture-base) $"proj-collide-(random chars --length 6)"] | path join)
        let repo_ab = ($base | path join "a" "b")
        let repo_a_dash_b = ($"($base)-a-b")
        mkdir ($repo_ab | path dirname)
        ^git init -q -b main $repo_ab
        ^git -C $repo_ab commit -q --allow-empty -m seed
        ^git init -q -b main $repo_a_dash_b
        ^git -C $repo_a_dash_b commit -q --allow-empty -m seed

        let root = (make-runtime "proj-collide")
        with-runtime $root {
            let d1 = (do { cd $repo_ab; project-dir })
            let d2 = (do { cd $repo_a_dash_b; project-dir })
            assert-true ($d1 != $d2) $"/a/b and /a-b must not share a project dir: both resolved to ($d1)"
        }
        rm -rf $root; rm -rf $base; rm -rf $repo_a_dash_b
    })

    (run-case "project/outside-a-repository-is-refused-and-creates-nothing" {
        let outside = ([(fixture-base) $"proj-outside-(random chars --length 6)"] | path join)
        mkdir $outside
        let root = (make-runtime "proj-outside")
        with-runtime $root {
            assert-rejects { do { cd $outside; project-dir } } "no project" "the refusal names what could not be resolved"
            assert-true (not ($root | path join "pi-worker" | path exists)) "no directory was created by the failed lookup"
        }
        rm -rf $root; rm -rf $outside
    })

    (run-case "project/bus-messages-and-queue-are-created-0700" {
        let repo = (make-repo "proj-perm")
        let root = (make-runtime "proj-perm")
        with-runtime $root {
            do { cd $repo; ensure-bus-dirs }
            let dir = (do { cd $repo; project-dir })
            for sub in ["messages" "queue"] {
                let d = ($dir | path join $sub)
                assert-true ($d | path exists) $"($d) must exist"
                assert-eq (dir-mode-of $d) "rwx------" $"($d) must be 0700"
            }
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "project/every-ancestor-of-bus-is-0700-not-just-the-leaf" {
        # `mkdir -m MODE -p` applies MODE only to the FINAL path component;
        # `pi-worker/` and `pi-worker/<slug>/` are ancestors `-p` creates
        # along the way to `bus/`, so a single `ensure-dir (project-dir)`
        # call leaves them at the umask mode (0755 here) instead of 0700 —
        # leaking the slug, and so the repo's identity, to every local user.
        # `make-runtime` hands every case its own fresh XDG_RUNTIME_DIR, so
        # neither ancestor can already exist from an earlier case.
        let repo = (make-repo "proj-perm-ancestors")
        let root = (make-runtime "proj-perm-ancestors")
        with-runtime $root {
            do { cd $repo; ensure-bus-dirs }
            let dir = (do { cd $repo; project-dir })
            let project_root = ($dir | path dirname)
            let pi_worker_root = ($project_root | path dirname)
            assert-eq $pi_worker_root ($root | path join "pi-worker") "sanity: this is the pi-worker root, not some other ancestor"
            for d in [$pi_worker_root $project_root $dir] {
                assert-eq (dir-mode-of $d) "rwx------" $"($d) must be 0700, not the umask default"
            }
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "project/a-loosened-bus-tree-is-still-refused-by-ensure-bus-dirs" {
        # `ensure-bus-dirs` reuses `ensure-dir` / `bus-assert-owned` unchanged
        # rather than re-checking ownership itself, so this proves the
        # refusal survives into the new call path. Ownership-by-another-uid
        # is exercised directly against `bus-assert-owned` (via `/proc`,
        # which is real and root-owned) in
        # "bus/rejects-a-runtime-directory-owned-by-another-user" above —
        # not repeated here since the check is the same function either way.
        let repo = (make-repo "proj-owner")
        let root = (make-runtime "proj-owner")
        with-runtime $root {
            let dir = (do { cd $repo; project-dir })
            mkdir $dir
            chmod 777 $dir
            assert-rejects { do { cd $repo; ensure-bus-dirs } } "not 0700" "a world-writable bus tree is refused, not silently used"
        }
        rm -rf $root; rm -rf $repo
    })

    # ----------------------------------------- peer-addressed send (sp029 T3)
    #
    # `bus-send` replaces the run/uid inbox model with `to`/`from`/`content`
    # against the project bus: one message in `bus/messages/`, one 32-byte row
    # per recipient in `bus/queue/<uid>`, publish by rename LAST. The legacy
    # `legacy-inbox-send`/`claim-slot` path above is untouched and still backs
    # `worker-resume` and the `main send` CLI verb pending T7-T9.

    (run-case "send/fan-out-writes-one-message-and-a-row-in-each-recipients-queue" {
        let repo = (make-repo "send-fanout")
        let root = (make-runtime "send-fanout")
        with-runtime $root {
            do { cd $repo; bus-send --to ["a" "b"] --from "sender-1" --content "do the thing" }
            let dir = (do { cd $repo; project-dir })

            let messages = (ls ($dir | path join "messages") | get name)
            assert-eq ($messages | length) 1 "exactly one message file"
            let message_mtime = (ls $messages.0 | get 0.modified)

            for uid in ["a" "b"] {
                let qpath = ($dir | path join "queue" $uid)
                let raw = (open --raw $qpath)
                assert-eq ($raw | str length) $QUEUE_ROW_BYTES $"($uid)'s queue holds exactly one fixed-width row"
                let row_mtime = (ls $qpath | get 0.modified)
                assert-true ($message_mtime > $row_mtime) $"the message's mtime must be later than ($uid)'s row append — rows first, publish last"
            }
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/interrupting-between-fanout-and-publish-leaves-no-message-and-clean-zero-mail" {
        # The ordering fault: stage a message (rows appended, envelope written
        # to a scratch name) and simply never publish it — standing in for a
        # sender that dies right there. `bus-send` itself is `bus-publish-
        # message (bus-stage-message ...)`, so calling only the first half is
        # exactly "died before the rename," not a test-only hook.
        let repo = (make-repo "send-fault")
        let root = (make-runtime "send-fault")
        with-runtime $root {
            do { cd $repo; bus-stage-message --to ["a"] --from "sender-1" --content "never arrives" }

            let dir = (do { cd $repo; project-dir })
            assert-eq (ls ($dir | path join "messages") | length) 0 "an unpublished stage leaves no message file"

            let unread = (do { cd $repo; unread-rows "a" })
            assert-eq ($unread | length) 1 "the row was appended before the crash"

            let deliverable = (do { cd $repo; deliverable-mail "a" })
            assert-true ($deliverable | is-empty) "a reader resolving the row against messages/ sees clean zero mail, not an error"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/publish-refuses-when-some-recipients-rows-are-missing" {
        # `bus-publish-message` is structural, not advisory: even called
        # directly (not through `bus-send`) on a staged handle whose fan-out
        # never reached every recipient — a future caller getting the row
        # count wrong, not just a crash — it must refuse rather than make the
        # message visible to no one for that recipient. Here `a` has its row
        # and `b` does not: a PARTIAL fan-out.
        let repo = (make-repo "send-publish-guard-partial")
        let root = (make-runtime "send-publish-guard-partial")
        with-runtime $root {
            let staged = (do { cd $repo; bus-stage-message --to ["a" "b"] --from "sender-1" --content "hi" })
            let dir = (do { cd $repo; project-dir })
            rm -f ($dir | path join "queue" "b")

            assert-rejects {
                do { cd $repo; bus-publish-message $staged }
            } $staged.msg_id "publish refuses, naming the message id, when a recipient's row never landed"

            assert-eq (ls ($dir | path join "messages") | length) 0 "the refused publish leaves no message file"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/publish-refuses-when-no-recipients-rows-were-appended" {
        # The other end of the same guard: NEITHER recipient's row landed —
        # standing in for a caller that skipped fan-out entirely, not merely
        # got interrupted partway through it.
        let repo = (make-repo "send-publish-guard-none")
        let root = (make-runtime "send-publish-guard-none")
        with-runtime $root {
            let staged = (do { cd $repo; bus-stage-message --to ["a" "b"] --from "sender-1" --content "hi" })
            let dir = (do { cd $repo; project-dir })
            rm -f ($dir | path join "queue" "a")
            rm -f ($dir | path join "queue" "b")

            assert-rejects {
                do { cd $repo; bus-publish-message $staged }
            } $staged.msg_id "publish refuses, naming the message id, when no recipient's row landed"

            assert-eq (ls ($dir | path join "messages") | length) 0 "the refused publish leaves no message file"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/concurrent-senders-produce-well-formed-non-interleaved-rows" {
        let repo = (make-repo "send-concurrent")
        let root = (make-runtime "send-concurrent")
        with-runtime $root {
            let script = ([$root "send-writer.nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\nlet n = \$env.WRITER_N\nfor i in 1..50 { bus-send --to [\"shared\"] --from \$\"writer-\($n)\" --content \$\"msg-\($n)-\($i)\" }" | save -f $script

            let procs = ([1 2] | par-each {|n|
                with-env {XDG_RUNTIME_DIR: $root, WRITER_N: ($n | into string)} {
                    do { cd $repo; ^$nu.current-exe $script } | complete
                }
            })
            for p in $procs { assert-eq $p.exit_code 0 $"writer failed: ($p.stderr)" }

            let dir = (do { cd $repo; project-dir })
            let raw = (open --raw ($dir | path join "queue" "shared"))
            assert-eq ($raw | str length) (100 * $QUEUE_ROW_BYTES) "100 rows landed at exactly the fixed width — no interleaving, no truncation"

            let rows = (do { cd $repo; queue-rows "shared" })
            assert-eq ($rows | length) 100 "100 well-formed rows"
            assert-eq ($rows | get id | uniq | length) 100 "no two messages share an id"

            let messages_dir = ($dir | path join "messages")
            for row in $rows {
                assert-true (($messages_dir | path join $row.id) | path exists) $"row ($row.id) must resolve to a real message"
            }
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/reader-skips-a-truncated-row-and-still-reads-the-following-row" {
        let repo = (make-repo "send-truncated")
        let root = (make-runtime "send-truncated")
        with-runtime $root {
            do { cd $repo; ensure-bus-dirs }
            let dir = (do { cd $repo; project-dir })
            let qpath = ($dir | path join "queue" "a")

            # A row one byte short of the fixed width — 25 id characters
            # instead of 26 — still newline-terminated, standing in for a
            # write that was cut one byte short of the full id.
            let short_id = ("Z" | fill --width 25 --character "Z")
            $"($short_id)     \n" | save --append --raw $qpath

            let sent = (do { cd $repo; bus-send --to ["a"] --from "sender-1" --content "the real one" })

            let rows = (do { cd $repo; queue-rows "a" })
            assert-eq ($rows | length) 1 "the malformed row is skipped, not counted"
            assert-eq $rows.0.id $sent.id "the well-formed row appended after it is still read correctly"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/sending-to-an-unclaimed-address-succeeds" {
        let repo = (make-repo "send-unclaimed")
        let root = (make-runtime "send-unclaimed")
        with-runtime $root {
            let sent = (do { cd $repo; bus-send --to ["nobody-home"] --from "sender-1" --content "hello?" })
            let deliverable = (do { cd $repo; deliverable-mail "nobody-home" })
            assert-eq ($deliverable | length) 1 "sending never requires the recipient to exist"
            assert-eq $deliverable.0.id $sent.id ""
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/a-recipients-queue-file-is-created-0600-on-first-append" {
        let repo = (make-repo "send-perm")
        let root = (make-runtime "send-perm")
        with-runtime $root {
            do { cd $repo; bus-send --to ["a"] --from "sender-1" --content "hi" }
            let dir = (do { cd $repo; project-dir })
            assert-eq (mode-of ($dir | path join "queue" "a")) "rw-------" "a recipient's first queue file must be private"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/a-dangling-symlink-queue-is-refused" {
        let repo = (make-repo "send-symlink")
        let root = (make-runtime "send-symlink")
        with-runtime $root {
            do { cd $repo; ensure-bus-dirs }
            let dir = (do { cd $repo; project-dir })
            ^ln -s "/nonexistent-target-for-pi-worker-tests" ($dir | path join "queue" "a")

            assert-rejects {
                do { cd $repo; bus-send --to ["a"] --from "sender-1" --content "hi" }
            } "symlink" "a dangling queue symlink is refused, never silently followed or overwritten"
            assert-eq (ls ($dir | path join "messages") | length) 0 "the refused send publishes nothing"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/duplicate-recipients-after-dedup-produce-exactly-one-row" {
        let repo = (make-repo "send-dedup")
        let root = (make-runtime "send-dedup")
        with-runtime $root {
            do { cd $repo; bus-send --to ["a" "a" "a"] --from "sender-1" --content "hi" }
            let dir = (do { cd $repo; project-dir })
            let raw = (open --raw ($dir | path join "queue" "a"))
            assert-eq ($raw | str length) $QUEUE_ROW_BYTES "addressing one recipient three times still writes exactly one row"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/an-empty-to-is-refused-and-creates-nothing" {
        let repo = (make-repo "send-empty-to")
        let root = (make-runtime "send-empty-to")
        with-runtime $root {
            assert-rejects {
                do { cd $repo; bus-send --to [] --from "sender-1" --content "hi" }
            } "at least one address" ""
            assert-true (not ((do { cd $repo; project-dir }) | path exists)) "a rejected send creates no directory at all"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/content-at-exactly-64-KiB-is-refused-once-the-envelope-wrapper-is-counted" {
        # dotfiles-6nvx.14: `validate-envelope`'s own content-only check
        # happily accepts content at exactly 64 KiB (schema/accepts-content-
        # at-exactly-64-KiB in schema-cases.nu proves that, deliberately —
        # the schema validator measures content alone). But wrapped in this
        # envelope's own protocol/kind/id/from/to/created JSON, the TOTAL
        # bytes are over 64 KiB, and nothing enforced that total until now.
        # `bus-send` is the first thing that actually writes an envelope to
        # disk, so it is where the total gets checked.
        let repo = (make-repo "send-envelope-cap")
        let root = (make-runtime "send-envelope-cap")
        with-runtime $root {
            let huge = ("x" | fill --width 65536 --character "x")
            assert-rejects {
                do { cd $repo; bus-send --to ["a"] --from "sender-1" --content $huge }
            } "over the 64 KiB cap" "the write path enforces the envelope total, not just content"
            assert-true (not ((do { cd $repo; project-dir }) | path exists)) "a refused send creates no directory at all"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "send/content-comfortably-under-the-cap-is-accepted" {
        let repo = (make-repo "send-envelope-ok")
        let root = (make-runtime "send-envelope-ok")
        with-runtime $root {
            let ok = ("x" | fill --width 65000 --character "x")
            let sent = (do { cd $repo; bus-send --to ["a"] --from "sender-1" --content $ok })
            assert-eq $sent.content $ok "content well clear of the wrapper overhead is written as-is"
        }
        rm -rf $root; rm -rf $repo
    })

    # -------------------------------------------- read side, in-place marking, pruning (sp029 T4)

    (run-case "wait/reads-only-its-own-queue-and-never-scans-messages" {
        let repo = (make-repo "wait-scoped")
        let root = (make-runtime "wait-scoped")
        with-runtime $root {
            let for_a = (do { cd $repo; bus-send --to ["a"] --from "s" --content "for a" })
            let for_b = (do { cd $repo; bus-send --to ["b"] --from "s" --content "for b" })

            let mail_a = (do { cd $repo; bus-wait --as "a" })
            assert-eq ($mail_a | length) 1 "a sees only its own mail"
            assert-eq $mail_a.0.id $for_a.id ""

            # A message that exists on disk but that no row in a's queue
            # names — proving delivery is driven by a's queue, not a scan of
            # messages/.
            let dir = (do { cd $repo; project-dir })
            assert-true (($dir | path join "messages" $for_b.id) | path exists) "sanity: b's message really is on disk"
            assert-true ($mail_a | where id == $for_b.id | is-empty) "a never sees a message it has no row for, even though it exists on disk"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "wait/an-absent-queue-file-is-zero-mail-not-an-error" {
        let repo = (make-repo "wait-absent")
        let root = (make-runtime "wait-absent")
        with-runtime $root {
            do { cd $repo; ensure-bus-dirs }
            let mail = (do { cd $repo; bus-wait --as "never-sent-to" })
            assert-true ($mail | is-empty) ""
            let rows = (do { cd $repo; queue-rows "never-sent-to" })
            assert-true ($rows | is-empty) ""
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "wait/a-queue-with-only-marked-rows-is-zero-mail-not-an-error" {
        let repo = (make-repo "wait-all-marked")
        let root = (make-runtime "wait-all-marked")
        with-runtime $root {
            let sent = (do { cd $repo; bus-send --to ["a"] --from "s" --content "hi" })
            do { cd $repo; queue-mark-read "a" $sent.id }
            let mail = (do { cd $repo; bus-wait --as "a" })
            assert-true ($mail | is-empty) "every row already marked is zero mail, not an error"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "wait/a-row-naming-a-pruned-or-otherwise-missing-message-is-inert-not-an-error" {
        let repo = (make-repo "wait-inert")
        let root = (make-runtime "wait-inert")
        with-runtime $root {
            let sent = (do { cd $repo; bus-send --to ["a"] --from "s" --content "vanishing" })
            let dir = (do { cd $repo; project-dir })
            rm -f ($dir | path join "messages" $sent.id)

            let mail = (do { cd $repo; bus-wait --as "a" })
            assert-true ($mail | is-empty) "a row naming a message that is no longer there resolves to nothing, not an error"
            let rows = (do { cd $repo; queue-rows "a" })
            assert-eq ($rows | length) 1 "the inert row itself is untouched"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "wait/block-returns-within-the-timeout-and-prints-nothing-when-empty" {
        let repo = (make-repo "wait-timeout")
        let root = (make-runtime "wait-timeout")
        with-runtime $root {
            do { cd $repo; ensure-bus-dirs }
            let start = (date now)
            let mail = (do { cd $repo; bus-wait --as "nobody" --block --timeout 1sec })
            let elapsed = ((date now) - $start)
            assert-true ($mail | is-empty) "nothing pending, so wait returns empty rather than hanging"
            assert-true ($elapsed < 3sec) $"a 1s timeout must not run long past its bound, took ($elapsed)"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "wait/block-returns-as-soon-as-mail-is-resolvable-not-after-the-full-timeout" {
        let repo = (make-repo "wait-block-hit")
        let root = (make-runtime "wait-block-hit")
        with-runtime $root {
            do { cd $repo; bus-send --to ["a"] --from "s" --content "hi" }
            let start = (date now)
            let mail = (do { cd $repo; bus-wait --as "a" --block --timeout 10sec })
            let elapsed = ((date now) - $start)
            assert-eq ($mail | length) 1 "already-pending mail is returned at once"
            assert-true ($elapsed < 3sec) $"must not wait out the full 10s timeout when mail is already there, took ($elapsed)"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "queue-mark-read/writes-exactly-five-bytes-leaves-every-other-row-byte-identical" {
        let repo = (make-repo "mark-bytes")
        let root = (make-runtime "mark-bytes")
        with-runtime $root {
            let first = (do { cd $repo; bus-send --to ["a"] --from "s" --content "row-1" })
            let second = (do { cd $repo; bus-send --to ["a"] --from "s" --content "row-2" })
            let dir = (do { cd $repo; project-dir })
            let path = ($dir | path join "queue" "a")
            let before = (open --raw $path)
            assert-eq ($before | str length) (2 * $QUEUE_ROW_BYTES) "sanity: two rows"

            do { cd $repo; queue-mark-read "a" $first.id }
            let after = (open --raw $path)

            assert-eq ($after | str length) ($before | str length) "file size is unchanged by a mark"
            let row2_before = ($before | str substring $QUEUE_ROW_BYTES..)
            let row2_after = ($after | str substring $QUEUE_ROW_BYTES..)
            assert-eq $row2_before $row2_after "the other row is byte-identical after the mark"

            let rows = (do { cd $repo; queue-rows "a" })
            assert-eq ($rows | where id == $first.id | get 0.read) true "the marked row now reads read"
            assert-eq ($rows | where id == $second.id | get 0.read) false "the untouched row is still unread"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "queue-mark-read/marks-the-last-row-in-the-file-correctly" {
        let repo = (make-repo "mark-last")
        let root = (make-runtime "mark-last")
        with-runtime $root {
            let first = (do { cd $repo; bus-send --to ["a"] --from "s" --content "row-1" })
            let last = (do { cd $repo; bus-send --to ["a"] --from "s" --content "row-2" })
            do { cd $repo; queue-mark-read "a" $last.id }

            let rows = (do { cd $repo; queue-rows "a" })
            assert-eq ($rows | where id == $last.id | get 0.read) true "the last row in the file was marked"
            assert-eq ($rows | where id == $first.id | get 0.read) false "the first row is untouched"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "queue-mark-read/marking-an-already-marked-row-is-idempotent" {
        let repo = (make-repo "mark-idempotent")
        let root = (make-runtime "mark-idempotent")
        with-runtime $root {
            let sent = (do { cd $repo; bus-send --to ["a"] --from "s" --content "hi" })
            do { cd $repo; queue-mark-read "a" $sent.id }
            let dir = (do { cd $repo; project-dir })
            let before = (open --raw ($dir | path join "queue" "a"))

            do { cd $repo; queue-mark-read "a" $sent.id }
            let after = (open --raw ($dir | path join "queue" "a"))
            assert-eq $before $after "marking twice writes the same five bytes both times"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "queue-mark-read/refuses-an-id-with-no-row-and-names-it" {
        let repo = (make-repo "mark-unknown")
        let root = (make-runtime "mark-unknown")
        with-runtime $root {
            do { cd $repo; bus-send --to ["a"] --from "s" --content "hi" }
            assert-rejects {
                do { cd $repo; queue-mark-read "a" "NOSUCHID0000000000000000A" }
            } "no row" "the refusal names that no row carries this id"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "queue-mark-read/refuses-when-the-queue-file-does-not-exist" {
        let repo = (make-repo "mark-no-queue")
        let root = (make-runtime "mark-no-queue")
        with-runtime $root {
            do { cd $repo; ensure-bus-dirs }
            assert-rejects {
                do { cd $repo; queue-mark-read "never-sent-to" "NOSUCHID0000000000000000A" }
            } "no queue file" ""
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "queue-mark-read/a-mark-and-a-concurrent-append-both-survive" {
        # The exact anti-pattern this row format exists to avoid: marking row
        # 1 while a sender appends row 50 must never read-modify-write the
        # whole file, or one of the two effects is lost.
        let repo = (make-repo "mark-concurrent")
        let root = (make-runtime "mark-concurrent")
        with-runtime $root {
            let first = (do { cd $repo; bus-send --to ["a"] --from "s" --content "row-1" })
            for i in 2..49 { do { cd $repo; bus-send --to ["a"] --from "s" --content $"row-($i)" } }

            let mark_script = ([$root "mark-writer.nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\nqueue-mark-read \"a\" \"($first.id)\"" | save -f $mark_script

            let append_script = ([$root "append-writer.nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\nbus-send --to [\"a\"] --from \"s\" --content \"row-50\"" | save -f $append_script

            let procs = ([1 2] | par-each {|n|
                let script = (if $n == 1 { $mark_script } else { $append_script })
                with-env {XDG_RUNTIME_DIR: $root} {
                    do { cd $repo; ^$nu.current-exe $script } | complete
                }
            })
            for p in $procs { assert-eq $p.exit_code 0 $"writer failed: ($p.stderr)" }

            let dir = (do { cd $repo; project-dir })
            let raw = (open --raw ($dir | path join "queue" "a"))
            assert-eq ($raw | str length) (50 * $QUEUE_ROW_BYTES) "all 50 rows present: the concurrent append was not dropped"

            let rows = (do { cd $repo; queue-rows "a" })
            assert-eq ($rows | length) 50 ""
            assert-eq ($rows | where id == $first.id | get 0.read) true "the mark survived the concurrent append"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "bus-prune/a-message-survives-until-every-recipient-has-marked" {
        let repo = (make-repo "prune-multi")
        let root = (make-runtime "prune-multi")
        with-runtime $root {
            let sent = (do { cd $repo; bus-send --to ["a" "b"] --from "s" --content "hi" })
            let dir = (do { cd $repo; project-dir })
            let msg_path = ($dir | path join "messages" $sent.id)

            do { cd $repo; queue-mark-read "a" $sent.id }
            let pruned_once = (do { cd $repo; bus-prune })
            assert-true ($sent.id not-in $pruned_once.pruned) "b has not marked yet, so the message stays"
            assert-true ($msg_path | path exists) "the message file survives while b is unmarked"

            do { cd $repo; queue-mark-read "b" $sent.id }
            let pruned_twice = (do { cd $repo; bus-prune })
            assert-true ($sent.id in $pruned_twice.pruned) "now both have marked, so it is collected"
            assert-true (not ($msg_path | path exists)) "the message file is gone"

            let rows_a = (do { cd $repo; queue-rows "a" })
            let rows_b = (do { cd $repo; queue-rows "b" })
            assert-eq ($rows_a | length) 1 "a's row is untouched, just inert now"
            assert-eq ($rows_b | length) 1 "b's row is untouched, just inert now"
        }
        rm -rf $root; rm -rf $repo
    })

]

$cases | to json
