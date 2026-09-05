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
use ../../claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu *

def make-tmux [tag: string]: nothing -> record {
    let socket = $"infinifu-t5-($tag)-(random chars --length 6)"
    let sandbox = ([$nu.temp-dir $"infinifu-t5-bin-($tag)-(random chars --length 6)"] | path join)
    mkdir $sandbox
    "#!/bin/bash\nsleep 30\n" | save -f ($sandbox | path join "pi")
    chmod +x ($sandbox | path join "pi")
    ^tmux -L $socket new-session -d -s "dotfiles" -n "main"
    {socket: $socket, bin: $sandbox}
}

def drop-tmux [t: record] {
    do { ^tmux -L $t.socket kill-server } | complete | ignore
    rm -rf $t.bin
}

def windows-on [socket: string]: nothing -> list<string> {
    ^tmux -L $socket list-windows -a -F "#{window_name}" | lines | each {|w| $w | str trim }
}

def launch [t: record, repo: string, uid: string, role: string, skill: string = "work-do"] {
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
        # Cleanup must not destroy the evidence trail: the resume command and
        # the reported result are what a later question is answered from.
        with-pipeline "evidence" {|t, repo|
            launch $t $repo "impl-a" "impl"
            complete-with "impl-a" "implemented"
            let done = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid "impl-a" --sequence $done.sequence
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket

            let seen = (worker-inspect "impl-a" --run "run-1")
            assert-eq $seen.identity.session "sid-impl-a" "the session id outlives the worktree"
            assert-eq $seen.last_result.status "complete" ""
            assert-eq $seen.resume "pi --session sid-impl-a" ""
        }
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
            "unsaved\n" | save -f ($impl.cwd | path join "notes.txt")
            complete-with "impl-a" "implemented"
            assert-rejects {
                worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            } "uncommitted" "acceptance does not license deleting unsaved work"
            assert-true ($impl.cwd | path exists) ""
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
            launch $t $repo "rev-a" "rev" "work-audit"
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
            launch $t $repo "rev-a" "rev" "work-audit"
            complete-with "impl-a" "done"

            let script = ([$nu.temp-dir $"t5-restart-(random chars --length 6).nu"] | path join)
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
            let theirs = (worker-spawn --run "run-2" --uid "impl-b" --role "impl" --subject "t2" --project "dotfiles" --repo $repo --task "t2" --session "sid-impl-b" --skill "work-do" --socket $t.socket)
            complete-with "impl-a" "mine done"

            let done = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid "impl-a" --sequence $done.sequence
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket

            assert-true ($theirs.window in (windows-on $t.socket)) "the other run's window is untouched"
            assert-true ($theirs.cwd | path exists) "as is its worktree"
            assert-eq (bus-status "impl-b" --run "run-2" | get state) "running" ""
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
]

$cases | to json
