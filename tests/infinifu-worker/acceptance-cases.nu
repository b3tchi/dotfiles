#!/usr/bin/env nu
# Operator acceptance suite (sp028 T7).
#
# The demonstration the spec asks for, run end to end through the CLI an
# operator actually types: a delegated spec-refinement returns a compact
# SRE-PASS envelope to the initiator, while its detailed worker window stays
# open and inspectable.
#
# The worker here is a STUB standing in for Pi — it writes its result through
# the same `infinifu-worker result` path a real worker uses. That makes this a
# real exercise of the bus, the stage gate, the window lifecycle and the
# acceptance cleanup, but NOT of Pi itself. The live-Pi half is a documented
# manual run (see README and the T7 notes); this suite is what can be proven
# on any machine, every time.

use harness.nu *
use ../../claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu *

def cli []: nothing -> string { worker-script $env.FILE_PWD }

def make-server [tag: string]: nothing -> record {
    let socket = $"infinifu-t7-($tag)-(random chars --length 6)"
    let sandbox = ([$nu.temp-dir $"infinifu-t7-bin-($tag)-(random chars --length 6)"] | path join)
    mkdir $sandbox
    # A stub worker that prints the sort of detail a real refinement produces,
    # then keeps its window alive so it can be inspected.
    $"#!/bin/bash\necho 'refining sp028: 7 tasks, dependency graph acyclic'\necho 'SRE review: granularity ok, implementability ok, success criteria ok'\nsleep 30\n" | save -f ($sandbox | path join "pi")
    chmod +x ($sandbox | path join "pi")
    ^tmux -L $socket new-session -d -s "dotfiles" -n "main"
    {socket: $socket, bin: $sandbox}
}

def drop-server [t: record] {
    drop-tmux-server $t.socket
    rm -rf $t.bin
}

def windows-on [socket: string]: nothing -> list<string> {
    ^tmux -L $socket list-windows -a -F "#{window_name}" | lines | each {|w| $w | str trim }
}

let cases = [
    (run-case "acceptance/delegated-refinement-returns-a-compact-sre-pass-envelope" {
        let t = (make-server "accept")
        let repo = (make-repo "accept")
        let root = (make-runtime "accept")
        guarded {
            with-runtime $root {
                with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                    # 1. Delegate a refinement to a visible worker.
                    let w = (worker-spawn --run "acceptance" --uid "rev-sp028" --role "rev" --subject "sp028" --project "dotfiles" --repo $repo --task "" --session "sid-acceptance" --skill "spec-refinement" --socket $t.socket)
                    assert-eq $w.window "rev-sp028@dotfiles" "the operator sees a named window"
                    assert-true ($w.window in (windows-on $t.socket)) ""

                    # 2. The worker reports through the CLI, as Pi's result tool does.
                    let wrote = (with-env {XDG_RUNTIME_DIR: $root} {
                        ^$nu.current-exe (cli) "send" "rev-sp028" "--run" "acceptance" "--stage" "spec-refinement" "--instructions" "refine sp028" "--artifacts" "sp028" | complete
                    })
                    assert-eq $wrote.exit_code 0 $"send failed: ($wrote.stderr)"

                    bus-result "rev-sp028" --run "acceptance" --result {
                        status: "complete"
                        summary: "sp028 refined into 7 tasks; dependency graph acyclic; every task under 16h"
                        validation: "SRE PASS"
                        window: $w.window
                        session: "sid-acceptance"
                        resume: "pi --session sid-acceptance"
                    }

                    # 3. The initiator receives a COMPACT envelope, via the CLI.
                    let waited = (with-env {XDG_RUNTIME_DIR: $root} {
                        ^$nu.current-exe (cli) "wait" "--run" "acceptance" | complete
                    })
                    assert-eq $waited.exit_code 0 $"wait failed: ($waited.stderr)"
                    let envelope = ($waited.stdout | from json)
                    assert-eq $envelope.payload.validation "SRE PASS" "the verdict arrives in the typed field"
                    assert-eq $envelope.payload.resume "pi --session sid-acceptance" "with an exact resume command"
                    assert-true ((envelope-bytes $envelope) < 2048) $"the envelope must stay compact, got (envelope-bytes $envelope) bytes"

                    # 4. Meanwhile the DETAIL is still in the window, not the envelope.
                    let pane = (^tmux -L $t.socket capture-pane -p -t $w.window | str trim)
                    assert-true ($pane | str contains "SRE review") "the worker's detail is on screen"
                    assert-true (not ($envelope.payload.summary | str contains "granularity")) "and not copied into the envelope"
                    assert-true ($w.window in (windows-on $t.socket)) "the window remains inspectable after completion"

                    # 5. Acceptance is the only thing that cleans up.
                    bus-ack --run "acceptance" --uid "rev-sp028" --sequence $envelope.sequence
                    assert-true ($w.window in (windows-on $t.socket)) "ack alone does not close it"

                    worker-accept "rev-sp028" --run "acceptance" --repo $repo --socket $t.socket
                    assert-true (not ($w.window in (windows-on $t.socket))) "acceptance closes the window"
                    assert-true (not ($w.cwd | path exists)) "and removes the worktree"

                    # 6. The evidence outlives the cleanup.
                    let seen = (worker-inspect "rev-sp028" --run "acceptance")
                    assert-eq $seen.last_result.validation "SRE PASS" ""
                    assert-eq $seen.resume "pi --session sid-acceptance" "the worker is still resumable by session id"
                }
            }
        } { drop-server $t; rm -rf $root; rm -rf $repo }
    })

    (run-case "acceptance/a-refinement-without-sre-pass-never-reaches-the-initiator" {
        # The same flow with the verdict a careless worker would produce. The
        # envelope must never be written, so `wait` has nothing to hand over.
        let t = (make-server "gate")
        let repo = (make-repo "gate")
        let root = (make-runtime "gate")
        guarded {
            with-runtime $root {
                with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                    let w = (worker-spawn --run "acceptance" --uid "rev-sp028" --role "rev" --subject "sp028" --project "dotfiles" --repo $repo --task "" --session "sid-gate" --skill "spec-refinement" --socket $t.socket)
                    assert-rejects {
                        bus-result "rev-sp028" --run "acceptance" --result {
                            status: "complete", summary: "Looks thorough to me. SRE PASS."
                            validation: "looks good", window: $w.window
                            session: "sid-gate", resume: "pi --session sid-gate"
                        }
                    } "SRE PASS" "the stage gate refuses it"
                    assert-true ((bus-wait --run "acceptance") | is-empty) "so the initiator is never told it passed"
                    assert-true ($w.window in (windows-on $t.socket)) "and the worker stays up to be fixed"
                }
            }
        } { drop-server $t; rm -rf $root; rm -rf $repo }
    })
]

$cases | to json
