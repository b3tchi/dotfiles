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

let cases = [
    # ------------------------------------------------------ addressed round trip
    (run-case "bus/send-then-worker-reads-its-own-inbox" {
        let root = (make-runtime "roundtrip")
        with-runtime $root {
            bus-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "dotfiles-963w.2"}
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
            for i in 1..4 { bus-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: $"t-($i)"} }
            let seqs = (bus-inbox "impl-a" --run "run-1" | get sequence)
            assert-eq $seqs [1 2 3 4] "sequences increase by one and arrive in order"
        }
        rm -rf $root
    })

    # ------------------------------------------------------------- permissions
    (run-case "bus/runtime-directories-are-0700" {
        let root = (make-runtime "perm-dir")
        with-runtime $root {
            bus-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
            for dir in [(bus-root) (bus-root | path join "run-1") (bus-root | path join "run-1" "impl-a")] {
                assert-eq (dir-mode-of $dir) "rwx------" $"($dir) must not be readable by other users"
            }
        }
        rm -rf $root
    })

    (run-case "bus/envelope-files-are-0600" {
        let root = (make-runtime "perm-file")
        with-runtime $root {
            bus-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
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
            $"use (worker-script $env.FILE_PWD) *\nlet n = \$env.WRITER_N\nfor i in 1..10 { bus-send \"impl-a\" --run \"run-1\" --payload {stage: \"wk-build\", task: \$\"t-\(\$n)-\(\$i)\"} }" | save -f $script

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
                bus-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t", design: "copied prose"}
            } "wk-build" "a payload violating the protocol never reaches the runtime dir"
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
            bus-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
            # /proc is root-owned and always present; standing in for a planted tree.
            assert-rejects { bus-assert-owned "/proc" } "owner" "a directory owned by another user is refused"
            bus-assert-owned (bus-root)
        }
        rm -rf $root
    })

    (run-case "bus/rejects-a-loosened-runtime-directory" {
        let root = (make-runtime "loose")
        with-runtime $root {
            bus-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
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
            bus-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t"}
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
            bus-send "w1" --run "r1" --payload {stage: "doc-draft", instructions: "do the thing"}
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
        with-runtime $root {
            assert-eq (mint-uid "r1" "impl") "impl-1" "the first of a role"
            bus-identity "impl-1" --run "r1" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                session: "s", skill: "wk-build", window: "impl-1@dotfiles"
            }
            assert-eq (mint-uid "r1" "impl") "impl-2" "the next one skips the taken address"
            assert-eq (mint-uid "r1" "rev") "rev-1" "counted per role, not per run"
            assert-eq (mint-uid "r2" "impl") "impl-1" "and per run, not globally"
        }
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

    # `mint-run` is retired by sp029 T1 (project scoping replaces run
    # scoping); `spawn`'s own minted-run behavior is CLI surface owned by T9
    # and out of scope here. See the `project/*` cases below for what
    # replaces it.

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
            let got = (bus-wait --run "r1" --uid "w1" --block --timeout 10sec)
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
            bus-send "w1" --run "r1" --payload {stage: "wk-build", task: "t"}
            let started = (date now)
            let got = (bus-wait --run "r1" --uid "w1" --block --timeout 2sec)
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
            bus-send "w1" --run "r1" --payload {stage: "wk-build", task: "t"}
            let started = (date now)
            assert-eq (bus-wait --run "r1" --uid "w1") null "still nothing pending"
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
            bus-send "b" --run "r1" --payload {stage: "wk-build", task: "t"}

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
                status: "complete", summary: "fresh", window: "w", session: "s", resume: "r"
            }

            # Unscoped keeps its meaning: oldest first, across the run.
            assert-eq (bus-wait --run "r1" | get uid) "old" "the run-wide wait is unchanged"
            # Scoped answers about the worker asked about.
            assert-eq (bus-wait --run "r1" --uid "new" | get payload.summary) "fresh" "scoped to the worker"
            assert-eq (bus-wait --run "r1" --uid "old" | get payload.summary) "stale" ""
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

            assert-eq (bus-wait --run "run-1" --uid "impl-a" --after 1) null "nothing newer than what the caller has seen"
            assert-eq (bus-wait --run "run-1" --uid "impl-a" | get sequence) 1 "and the earlier envelope is still pending for anyone asking plainly"

            put-result "run-1" "impl-a" {summary: "second round"}
            let newer = (bus-wait --run "run-1" --uid "impl-a" --after 1)
            assert-eq $newer.sequence 2 "the round the caller had not seen"
            assert-eq $newer.payload.summary "second round" ""
            assert-eq (bus-wait --run "run-1" --uid "impl-a" | get sequence) 1 "the plain wait is unchanged: oldest unacked first"
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
            assert-eq (bus-wait --run "run-1" --uid "impl-a" --after 0 | get sequence) 1 ""
            assert-eq (bus-wait --run "run-1" --uid "impl-a" | get sequence) 1 ""
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
                bus-wait --run "run-1" --after 1
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
            let got = (bus-wait --run "run-1" --uid "impl-a" --after 1 --block --timeout 10sec)
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
            assert-eq (bus-wait --run "r1" --uid "a") null "silence, not someone else's mail"
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

]

$cases | to json
