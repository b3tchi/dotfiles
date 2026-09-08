#!/usr/bin/env nu
# End-to-end pipeline cases (sp028 T5).
#
# These drive the whole implementer -> reviewer -> merge loop through the same
# CLI verbs the scrum-master's Pi branch uses, against a private tmux server, a
# stub `pi`, a throwaway repo and an isolated runtime dir. No model, no network.
#
# The point is the transitions between the pieces, which is where an
# orchestration bug lives: a rejection that starts a fresh worker instead of
# resuming the original, an acceptance that cleans up work nobody reviewed, or
# a cleanup that reaches into another run.

use harness.nu *
use ../../claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu *

def make-tmux [tag: string]: nothing -> record {
    let socket = (new-tmux-socket $"t5-($tag)")
    let sandbox = ([(fixture-base) $"piw-t5-bin-($tag)-(random chars --length 6)"] | path join)
    mkdir $sandbox
    "#!/bin/bash\nsleep 30\n" | save -f ($sandbox | path join "pi")
    chmod +x ($sandbox | path join "pi")
    ^tmux -L $socket new-session -d -s "dotfiles" -n "main"
    {socket: $socket, bin: $sandbox}
}

def drop-tmux [t: record] {
    drop-tmux-server $t.socket
    rm -rf $t.bin
}

def windows-on [socket: string]: nothing -> list<string> {
    ^tmux -L $socket list-windows -a -F "#{window_name}" | lines | each {|w| $w | str trim }
}

def launch [t: record, repo: string, uid: string, role: string, skill: string = "wk-build"] {
    worker-spawn --run "run-1" --uid $uid --role $role --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session $"sid-($uid)" --skill $skill --socket $t.socket
}

def complete-with [uid: string, summary: string, status: string = "complete"] {
    let verdict = (if $status == "complete" { "PASS" } else { null })
    bus-result $uid --run "run-1" --result {
        status: $status, summary: $summary, validation: $verdict
        window: $"($uid)@dotfiles", session: $"sid-($uid)", resume: $"pi --session sid-($uid)"
    }
}

# One case's whole world: repo + runtime + private tmux.
def with-pipeline [tag: string, body: closure] {
    let repo = (make-repo $tag)
    let root = (make-runtime $tag)
    let t = (make-tmux $tag)
    let outcome = (try {
        with-runtime $root { with-env {PATH: ([$t.bin] ++ $env.PATH)} { do $body $t $repo } }
        null
    } catch {|e| $e })
    drop-tmux $t; rm -rf $root; rm -rf $repo
    if $outcome != null { error make {msg: $outcome.msg} }
}

let cases = [
    # ----------------------------------------------------------- approve path
    (run-case "pipeline/approve-then-accept-cleans-only-after-acceptance" {
        with-pipeline "approve" {|t, repo|
            let impl = (launch $t $repo "impl-a" "impl")
            complete-with "impl-a" "implemented"

            # The initiator reads a compact envelope, not a transcript.
            let done = (bus-wait --run "run-1")
            assert-eq $done.payload.status "complete" ""
            assert-eq $done.payload.resume "pi --session sid-impl-a" "and can resume the named worker"
            assert-true ((envelope-bytes $done) < 2048) "the completion stays compact"
            bus-ack --run "run-1" --uid "impl-a" --sequence $done.sequence

            # Acknowledged is not accepted: the window is still inspectable.
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "complete" ""
            assert-true ($impl.window in (windows-on $t.socket)) "a completed worker stays visible"
            assert-true ($impl.cwd | path exists) "and its worktree survives review"

            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "accepted" ""
            assert-true (not ($impl.window in (windows-on $t.socket))) "acceptance closes the window"
            assert-true (not ($impl.cwd | path exists)) "and removes the worktree"
        }
    })

    (run-case "pipeline/accept-keeps-the-session-and-result-readable" {
        # Cleanup must not destroy the evidence trail: the session id and the
        # reported result are what a later question is answered from.
        #
        # This case used to assert `resume` was still `pi --session sid-impl-a`
        # after acceptance. That was the false promise in dotfiles-lr2w: Pi
        # binds a session to the directory it was created in, and accept has
        # just removed it, so that command refuses to start. The id and the
        # result do outlive the worktree — the command to reach them does not.
        let empty_sessions = ([(fixture-base) $"infinifu-nosessions-(random chars --length 6)"] | path join)
        mkdir $empty_sessions
        with-pipeline "evidence" {|t, repo|
            launch $t $repo "impl-a" "impl"
            complete-with "impl-a" "implemented"
            let done = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid "impl-a" --sequence $done.sequence
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket

            let seen = (worker-inspect "impl-a" --run "run-1" --sessions-dir $empty_sessions)
            assert-eq $seen.identity.session "sid-impl-a" "the session id outlives the worktree"
            assert-eq $seen.last_result.status "complete" "as does the reported result"
            assert-true ($seen.resume | str contains "no longer exists") $"and the hint admits the directory is gone, got ($seen.resume)"
        }
        rm -rf $empty_sessions
    })

    (run-case "pipeline/only-a-complete-worker-may-be-accepted" {
        # The T1 transition table says complete -> accepted is the only edge in.
        # A blocked worker being accepted would clean up unfinished work.
        with-pipeline "gate" {|t, repo|
            launch $t $repo "impl-a" "impl"
            complete-with "impl-a" "needs a decision" "blocked"
            assert-rejects {
                worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            } "blocked" "acceptance is refused for a worker that did not complete"
        }
    })

    (run-case "pipeline/accept-refuses-a-worker-with-uncommitted-work" {
        with-pipeline "dirty" {|t, repo|
            let impl = (launch $t $repo "impl-a" "impl")
            # Dirtied AFTER the report, because reporting `complete` from a
            # dirty worktree is now refused at the report itself — in front of
            # the worker, which can still fix it. This case is the guard BEHIND
            # that one: a tree can go dirty after a clean completion, and
            # acceptance must still not delete unsaved work.
            complete-with "impl-a" "implemented"
            "unsaved\n" | save -f ($impl.cwd | path join "notes.txt")
            assert-rejects {
                worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            } "uncommitted" "acceptance does not license deleting unsaved work"
            assert-true ($impl.cwd | path exists) ""
        }
    })

    (run-case "pipeline/a-refused-acceptance-can-be-retried-once-the-work-is-preserved" {
        # dotfiles-pwxf, observed on a live two-worker run: both workers
        # committed on their own branches and reported complete, and `accept`
        # removed each worktree and THEN declined to delete the branch. State
        # stayed `complete` with the tree already gone, every retry re-ran the
        # same refusal, and `rm` refuses anything not accepted or stopped — so
        # the address could only be freed by `stop`, which records a teardown
        # that did not happen.
        #
        # What makes it recoverable is that the refusal costs nothing: the
        # window, the tree and the branch all survive, and the same acceptance
        # succeeds once the work is somewhere else.
        with-pipeline "accept-retry" {|t, repo|
            let impl = (launch $t $repo "impl-a" "impl")
            "work\n" | save -f ($impl.cwd | path join "work.txt")
            ^git -C $impl.cwd add -A
            ^git -C $impl.cwd commit -q -m "work only this branch holds"
            complete-with "impl-a" "implemented"

            assert-rejects {
                worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            } "no other ref" "unpreserved work is not accepted away"
            assert-true ($impl.cwd | path exists) "the tree survives the refusal"
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "complete" "and so does the state that can still be accepted"
            assert-true ($impl.window in (windows-on $t.socket)) "the window is still there to be looked at"

            ^git -C $repo merge --no-ff -q -m "land it" $impl.branch
            let done = (worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket)
            assert-eq $done.state "accepted" "the retry lands once the work is preserved"
            assert-true (not ($impl.cwd | path exists)) "and the tree is reclaimed"
        }
    })

    (run-case "pipeline/complete-is-refused-while-the-worktree-is-dirty" {
        # The refusal the operator hit at the wrong moment:
        #
        #     accept refused: refusing to clean up .../wk-timestamp-file.1: it
        #     holds uncommitted work, which acceptance does not license deleting
        #
        # Right refusal, too late — the worker had already declared success and
        # gone quiet, leaving a finished worker that cannot be accepted and a
        # worktree that cannot be cleaned. Refused at the report instead, while
        # the only party who can commit is still working.
        with-pipeline "dirty-report" {|t, repo|
            let impl = (launch $t $repo "impl-a" "impl")
            "unsaved\n" | save -f ($impl.cwd | path join "notes.txt")
            assert-rejects { complete-with "impl-a" "implemented" } "uncommitted" "a complete that would be deleted is refused"
            # And the worker can still say it is stuck, which is the whole
            # reason only `complete` is gated.
            bus-result "impl-a" --run "run-1" --result {
                status: "blocked", summary: "cannot commit", window: "w", session: "s"
                resume: "pi --session s", validation: "n/a"
            }
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "blocked" "blocked is not gated"
        }
    })

    # ------------------------------------------------------- reject and resume
    (run-case "pipeline/rejection-resumes-the-original-session" {
        # The whole point of a stable session id: a rejected implementer keeps
        # its context instead of relearning the task from scratch.
        with-pipeline "reject" {|t, repo|
            let impl = (launch $t $repo "impl-a" "impl")
            complete-with "impl-a" "first attempt"
            let done = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid "impl-a" --sequence $done.sequence

            let resumed = (worker-resume "impl-a" --run "run-1" --feedback "criterion 2 is unmet" --socket $t.socket)

            assert-eq $resumed.session "sid-impl-a" "the SAME session, not a fresh worker"
            assert-eq $resumed.window $impl.window "in the same window"
            let inbox = (bus-inbox "impl-a" --run "run-1")
            assert-eq ($inbox | last | get payload.instructions) "criterion 2 is unmet" "feedback arrives as an addressed message"
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "running" "and the worker is running again"
        }
    })

    (run-case "pipeline/rejection-feedback-is-not-a-work-payload" {
        # Reviewer feedback is prose, so it travels as an AKM-shaped message.
        # Squeezing it into a work payload would violate the ticket-id-only rule.
        with-pipeline "feedback" {|t, repo|
            launch $t $repo "impl-a" "impl"
            complete-with "impl-a" "first attempt"
            worker-resume "impl-a" --run "run-1" --feedback "fix the gate" --socket $t.socket
            let msg = (bus-inbox "impl-a" --run "run-1" | last)
            assert-true ("task" not-in ($msg.payload | columns)) "feedback is not disguised as a ticket"
            assert-true ("instructions" in ($msg.payload | columns)) ""
        }
    })

    (run-case "pipeline/a-resumed-worker-has-no-result-left-to-deliver" {
        # dotfiles-nig0, observed live: impl-1 reported, was resumed with
        # feedback, and `wait --run` handed the SAME `complete` envelope back
        # instantly while `status` said `running`. An orchestrator draining a
        # run cannot tell that from a fresh report, so it acts on a result it
        # has already rejected — and there is no ordering that avoids it, since
        # `ack` is what clears delivery and `ack` releases the worker `resume`
        # needs alive.
        #
        # `reopened` already records which result was sent back; delivery has
        # to read it too, or the frame and the mailbox disagree.
        with-pipeline "reopened-wait" {|t, repo|
            launch $t $repo "impl-a" "impl"
            complete-with "impl-a" "first attempt"
            worker-resume "impl-a" --run "run-1" --feedback "criterion 2 is unmet" --socket $t.socket

            assert-eq (bus-wait --run "run-1") null "the superseded result is not pending"
            assert-eq (bus-wait --run "run-1" --uid "impl-a") null "nor when the worker is asked about directly"

            complete-with "impl-a" "second attempt"
            let fresh = (bus-wait --run "run-1")
            assert-eq $fresh.payload.summary "second attempt" "what arrives is the round the worker just reported"
            assert-eq $fresh.sequence 2 ""
        }
    })

    (run-case "pipeline/a-resumed-workers-mailbox-reads-empty-in-the-frame-too" {
        # dotfiles-ycvl, seen on the smoke run that verified the fix above:
        # `wait` correctly delivered nothing, while `workers` said
        #
        #     impl-1 complete unacked 2
        #     impl-2 complete unacked 1
        #
        # `unacked` is what an orchestrator skims to decide whether to call
        # `wait` at all, so counting envelopes delivery will never hand over
        # sends it looking for mail that is not there.
        with-pipeline "reopened-count" {|t, repo|
            launch $t $repo "impl-a" "impl"
            complete-with "impl-a" "first attempt"
            worker-resume "impl-a" --run "run-1" --feedback "again please" --socket $t.socket

            assert-eq (bus-status "impl-a" --run "run-1" | get unacked) 0 "a sent-back result is not waiting to be acknowledged"
            assert-eq (bus-status "impl-a" --run "run-1" | get results) 1 "the envelope is still on the bus, and still counted as history"

            complete-with "impl-a" "second attempt"
            assert-eq (bus-status "impl-a" --run "run-1" | get unacked) 1 "the fresh report is the one waiting"
        }
    })

    (run-case "pipeline/resuming-one-worker-does-not-hide-anothers-result" {
        # The other half of dotfiles-nig0: skipping a superseded envelope must
        # not turn into skipping the run. A sibling's unacknowledged result is
        # exactly what the orchestrator called `wait` for.
        with-pipeline "reopened-sibling" {|t, repo|
            launch $t $repo "impl-a" "impl"
            launch $t $repo "impl-b" "impl"
            complete-with "impl-a" "sent back"
            worker-resume "impl-a" --run "run-1" --feedback "not yet" --socket $t.socket
            complete-with "impl-b" "sibling done"

            let got = (bus-wait --run "run-1")
            assert-eq $got.uid "impl-b" "the run-wide wait skips the superseded envelope, not the run"
            assert-eq $got.payload.summary "sibling done" ""
        }
    })

    (run-case "pipeline/second-rejection-escalates-to-a-human" {
        # Two failures on the same task is the point where a human decides.
        # Looping a third time silently burns tokens on the same misunderstanding.
        with-pipeline "escalate" {|t, repo|
            launch $t $repo "impl-a" "impl"
            complete-with "impl-a" "attempt one"
            worker-resume "impl-a" --run "run-1" --feedback "gap 1" --socket $t.socket
            complete-with "impl-a" "attempt two"
            let second = (worker-resume "impl-a" --run "run-1" --feedback "gap 2" --socket $t.socket)

            assert-eq $second.escalate true "the second rejection asks for a human"
            assert-eq $second.rejections 2 ""
            let status = (bus-status "impl-a" --run "run-1")
            assert-eq $status.state "waiting_human" "and the worker is parked, not silently retried"
        }
    })

    # ------------------------------------------------------------- concurrency
    (run-case "pipeline/simultaneous-completions-are-both-delivered" {
        with-pipeline "both" {|t, repo|
            launch $t $repo "impl-a" "impl"
            launch $t $repo "rev-a" "rev" "wk-review"
            complete-with "impl-a" "impl done"
            complete-with "rev-a" "review done"

            let pending = (bus-pending "run-1")
            assert-eq ($pending | length) 2 "neither completion masks the other"
            let first = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid $first.uid --sequence $first.sequence
            let second = (bus-wait --run "run-1")
            assert-true ($second.uid != $first.uid) ""
        }
    })

    # ---------------------------------------------------------------- restart
    (run-case "pipeline/an-initiator-restart-reconstructs-from-the-bus-alone" {
        # Nothing about a run may live only in the orchestrator's memory. A
        # fresh process must be able to list its workers, their states, and how
        # to resume them, from the bus, git and tmux.
        with-pipeline "restart" {|t, repo|
            launch $t $repo "impl-a" "impl"
            launch $t $repo "rev-a" "rev" "wk-review"
            complete-with "impl-a" "done"

            let script = ([(fixture-base) $"t5-restart-(random chars --length 6).nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\nrun-workers \"run-1\" | to json" | save -f $script
            let out = (^$nu.current-exe $script | complete)
            assert-eq $out.exit_code 0 $"restart probe failed: ($out.stderr)"
            let seen = ($out.stdout | from json)

            assert-eq ($seen | get uid | sort) ["impl-a" "rev-a"] "every worker is discoverable"
            let impl = ($seen | where uid == "impl-a" | first)
            assert-eq $impl.state "complete" "with its state"
            assert-eq $impl.resume "pi --session sid-impl-a" "and its resume command"
            assert-eq $impl.unacked 1 "and its undelivered result"
            rm -f $script
        }
    })

    # --------------------------------------------------------------- isolation
    (run-case "pipeline/acceptance-cannot-reach-another-runs-worker" {
        with-pipeline "isolation" {|t, repo|
            let mine = (launch $t $repo "impl-a" "impl")
            let theirs = (worker-spawn --run "run-2" --uid "impl-b" --role "impl" --subject "t2" --project "dotfiles" --repo $repo --task "t2" --session "sid-impl-b" --skill "wk-build" --socket $t.socket)
            complete-with "impl-a" "mine done"

            let done = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid "impl-a" --sequence $done.sequence
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket

            assert-true ($theirs.window in (windows-on $t.socket)) "the other run's window is untouched"
            assert-true ($theirs.cwd | path exists) "as is its worktree"
            # Never reported, so `created` rather than `running`.
            assert-eq (bus-status "impl-b" --run "run-2" | get state) "created" ""
        }
    })

    (run-case "pipeline/accepting-an-unknown-worker-is-refused-not-guessed" {
        # adr0017: no evidence is not permission to act.
        with-pipeline "unknown" {|t, repo|
            assert-rejects {
                worker-accept "never-existed" --run "run-1" --repo $repo --socket $t.socket
            } "unknown" "a worker with no evidence is never cleaned up"
        }
    })

    # ------------------------------------------------------------------- stop
    (run-case "pipeline/stop-closes-the-window-but-keeps-the-work" {
        # Stopping is not accepting. The worktree holds possibly-unmerged work,
        # so it stays until something says the work is finished with.
        with-pipeline "stop" {|t, repo|
            let impl = (launch $t $repo "impl-a" "impl")
            worker-stop "impl-a" --run "run-1" --socket $t.socket

            assert-true (not ($impl.window in (windows-on $t.socket))) "the window is closed"
            assert-true ($impl.cwd | path exists) "but the worktree is kept"
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "stopped" ""
        }
    })

    (run-case "pipeline/a-stopped-worker-cannot-then-be-accepted" {
        with-pipeline "stopped-accept" {|t, repo|
            launch $t $repo "impl-a" "impl"
            worker-stop "impl-a" --run "run-1" --socket $t.socket
            assert-rejects {
                worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            } "stopped" "a stopped worker is terminal"
        }
    })

    # ------------------------------------------------------- merge-fail path
    (run-case "pipeline/cleanup-failure-leaves-the-evidence-readable" {
        # Merge succeeded, cleanup did not. The operator finishes by hand, so
        # everything they need must still be there.
        with-pipeline "mergefail" {|t, repo|
            let impl = (launch $t $repo "impl-a" "impl")
            "work\n" | save -f ($impl.cwd | path join "work.txt")
            ^git -C $impl.cwd add -A
            ^git -C $impl.cwd commit -q -m "work"
            complete-with "impl-a" "done"

            # An unmerged commit makes `git branch -d` refuse mid-cleanup.
            let outcome = (try { worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket; "no error" } catch {|e| $e.msg })
            assert-true ($outcome != "no error") "the partial cleanup is reported"

            let seen = (worker-inspect "impl-a" --run "run-1")
            assert-eq $seen.identity.session "sid-impl-a" "identity survives a partial cleanup"
            assert-eq $seen.last_result.status "complete" ""
        }
    })
    (run-case "pipeline/tearing-down-twice-is-a-no-op-not-an-error" {
        # Teardown is idempotent. An agent that retries `stop` — after a
        # timeout, or because it lost track — must not be told it did something
        # illegal for asking to stop something already stopped. `stopped` is
        # terminal, so the second call has nothing to do and says so.
        with-pipeline "idempotent-stop" {|t, repo|
            launch $t $repo "impl-a" "impl"
            worker-stop "impl-a" --run "run-1" --socket $t.socket
            let again = (worker-stop "impl-a" --run "run-1" --socket $t.socket)

            assert-eq (bus-status "impl-a" --run "run-1" | get state) "stopped" "still stopped"
            assert-true (not $again.changed) "the second call changed nothing"
        }
    })

    (run-case "pipeline/accepting-twice-is-a-no-op-not-an-error" {
        with-pipeline "idempotent-accept" {|t, repo|
            launch $t $repo "impl-a" "impl"
            complete-with "impl-a" "done"
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            let again = (worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket)

            assert-eq (bus-status "impl-a" --run "run-1" | get state) "accepted" "still accepted"
            assert-true (not $again.changed) "the second call changed nothing"
        }
    })

    (run-case "pipeline/an-accepted-worker-still-cannot-be-stopped" {
        # Idempotence is not permission. Acceptance is terminal and means the
        # work was taken; letting a later stop overwrite it would rewrite the
        # record of what happened.
        with-pipeline "no-stop-after-accept" {|t, repo|
            launch $t $repo "impl-a" "impl"
            complete-with "impl-a" "done"
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            assert-rejects {
                worker-stop "impl-a" --run "run-1" --socket $t.socket
            } "accepted" "an accepted worker is not stoppable"
        }
    })


]

$cases | to json
