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

# A result now requires the worker to have an identity, because that is where
# its stage gate comes from (T6). In production worker-spawn always records one
# before the process starts, so these cases record one too rather than
# exercising a state that cannot occur.
def put-result [run: string, uid: string, overrides: record = {}]: nothing -> record {
    if (bus-identity-of $uid --run $run) == null {
        bus-identity $uid --run $run --identity {
            role: "impl", cwd: "/tmp/nowhere", branch: $"bd-($uid).0"
            session: $"sid-($uid)", skill: "work-do", window: $"($uid)@dotfiles"
        }
    }
    bus-result $uid --run $run --result ((sample-result-args) | merge $overrides)
}

# A stand-in for ~/.pi/agent/sessions: one directory per project slug, each
# holding `<timestamp>_<uuid>.jsonl` transcripts.
def fake-sessions [tag: string, layout: record]: nothing -> string {
    let root = ([$nu.temp-dir $"infinifu-sessions-($tag)-(random chars --length 6)"] | path join)
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
                role: "impl", cwd: "/tmp/nowhere", branch: "bd-t1.0"
                session: "sid-1", skill: "work-do", window: "impl-a@dotfiles"
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
                role: "impl", cwd: "/tmp/nowhere", branch: "bd-t1.0"
                session: "sid-1", skill: "work-do", window: "impl-a@dotfiles"
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

            let file = (ls ($env.XDG_RUNTIME_DIR | path join "infinifu-worker" "r1" "impl-a" "outbox") | where name =~ '\.json$' | first | get name)
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
                role: "impl", cwd: "/tmp/nowhere", branch: "bd-t1.0"
                session: "sid-1", skill: "work-do", window: "impl-a@dotfiles"
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
    #   Stored session working directory does not exist: .../bd-t1.0
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
                role: "impl", cwd: $repo, branch: "bd-t1.0"
                session: "aaaa1111-2222-3333-4444-555566667777", skill: "work-do", window: "impl-a@dotfiles"
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
                role: "impl", cwd: "/nonexistent/bd-t1.0", branch: "bd-t1.0"
                session: "aaaa1111-2222-3333-4444-555566667777", skill: "work-do", window: "impl-a@dotfiles"
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
                role: "impl", cwd: "/nonexistent/bd-t1.0", branch: "bd-t1.0"
                session: "aaaa1111-2222-3333-4444-555566667777", skill: "work-do", window: "impl-a@dotfiles"
            }
            let seen = (worker-inspect "impl-a" --run "r1" --sessions-dir $sessions)
            assert-eq $seen.transcript null "no transcript found"
            assert-true ($seen.resume | str contains "no longer exists") $"say what happened, got ($seen.resume)"
        }
        rm -rf $root; rm -rf $sessions
    })


]

$cases | to json
