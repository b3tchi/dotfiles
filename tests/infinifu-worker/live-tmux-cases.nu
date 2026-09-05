#!/usr/bin/env nu
# Live tmux cases (sp028 T6).
#
# These run against a REAL tmux server — always a private one (`tmux -L`), so
# nothing here can touch a live session. poc022 hit that hazard directly and
# its recommendation was private sockets in integration tests.
#
# What is being proven is a negative: a completion travels through the bus and
# lands NOWHERE near a pane. The stale-target scenario is the one that matters.
# A worker's window id gets reused; something else — a shell, an editor, another
# Pi session — now occupies it. Any design that addressed workers by tmux target
# would, at that moment, type its message into someone else's session. This
# suite puts nushell in exactly that position and shows nothing arrives.

use harness.nu *
use ../../claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu *

def make-server [tag: string]: nothing -> record {
    let socket = $"infinifu-t6-($tag)-(random chars --length 6)"
    let sandbox = ([$nu.temp-dir $"infinifu-t6-bin-($tag)-(random chars --length 6)"] | path join)
    mkdir $sandbox
    "#!/bin/bash\nsleep 30\n" | save -f ($sandbox | path join "pi")
    chmod +x ($sandbox | path join "pi")
    ^tmux -L $socket new-session -d -s "dotfiles" -n "main"
    {socket: $socket, bin: $sandbox}
}

def drop-server [t: record] {
    drop-tmux-server $t.socket
    rm -rf $t.bin
}

# Read-only inspection of what a pane is showing. Reading is not messaging:
# capture-pane never writes to the pane, and it is used here only to prove the
# ABSENCE of injected text.
def pane-text [socket: string, target: string]: nothing -> string {
    let out = (do { ^tmux -L $socket capture-pane -p -t $target } | complete)
    if $out.exit_code != 0 { "" } else { $out.stdout }
}

def with-server [tag: string, body: closure] {
    let t = (make-server $tag)
    let root = (make-runtime $tag)
    let repo = (make-repo $tag)
    let outcome = (try {
        with-runtime $root { with-env {PATH: ([$t.bin] ++ $env.PATH)} { do $body $t $repo } }
        null
    } catch {|e| $e })
    drop-server $t; rm -rf $root; rm -rf $repo
    if $outcome != null { error make {msg: $outcome.msg} }
}

let cases = [
    # ------------------------------------------------ window ids vs pane ids
    (run-case "live/window-ids-and-pane-ids-are-distinct-namespaces" {
        # tmux hands out @1 for windows and %1 for panes, and they are easy to
        # confuse in a format string. Neither is used as an address here; this
        # case exists so a future change that starts treating one as the other
        # is caught, and so the distinction is documented in executable form.
        with-server "ids" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "work-do" --socket $t.socket)

            let window_id = (^tmux -L $t.socket list-windows -a -F "#{window_name} #{window_id}" | lines | where {|l| $l | str starts-with $w.window } | first | split row " " | last)
            let pane_id = (^tmux -L $t.socket list-panes -a -F "#{window_name} #{pane_id}" | lines | where {|l| $l | str starts-with $w.window } | first | split row " " | last)

            assert-true ($window_id | str starts-with "@") $"window id must look like @N, got ($window_id)"
            assert-true ($pane_id | str starts-with "%") $"pane id must look like %N, got ($pane_id)"
            assert-true ($window_id != $pane_id) "they are different namespaces"

            # The identity the bus records is the NAME, not either id: ids are
            # reused as windows come and go, names are addressed to a worker.
            let identity = (bus-identity-of "impl-a" --run "run-1")
            assert-eq $identity.window $w.window ""
            assert-true (not ($identity.window | str starts-with "@")) "identity never stores a window id"
            assert-true (not ($identity.window | str starts-with "%")) "nor a pane id"
        }
    })

    # --------------------------------------------------- the stale-target test
    (run-case "live/a-completion-injects-nothing-into-a-stale-target" {
        # The scenario in full: a worker runs, its window is torn down, and a
        # NEW window takes the same slot — here running nushell, standing in
        # for whatever an operator might have open. The worker then completes.
        #
        # If completions travelled by tmux, this is the moment a `send-keys`
        # would type into that shell. Nothing may appear in it.
        with-server "stale" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "work-do" --socket $t.socket)
            ^tmux -L $t.socket kill-window -t $w.window

            # Something else now occupies the slot the worker had.
            ^tmux -L $t.socket new-window -d -t "dotfiles" -n "someone-elses-shell" $nu.current-exe
            sleep 600ms
            let before = (pane-text $t.socket "someone-elses-shell")

            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "tests green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            sleep 600ms
            let after = (pane-text $t.socket "someone-elses-shell")

            assert-eq $after $before "the stale target's pane content is untouched by a completion"
            for trace in ["complete" "tests green" "sid-1" "impl-a"] {
                assert-true (not ($after | str contains $trace)) $"'($trace)' leaked into a pane"
            }

            # And the completion did arrive — at the run-scoped waiter.
            let got = (bus-wait --run "run-1")
            assert-eq $got.payload.status "complete" "the completion reached the CLI waiter"
        }
    })

    (run-case "live/no-worker-command-writes-to-a-pane" {
        # Every verb the pipeline uses, run against a live server with a
        # bystander window open, and the bystander asserted byte-identical
        # afterwards. This is the broad version of the case above: not just
        # completion, but the whole surface.
        with-server "surface" {|t, repo|
            ^tmux -L $t.socket new-window -d -t "dotfiles" -n "bystander" $nu.current-exe
            sleep 600ms
            let before = (pane-text $t.socket "bystander")

            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "work-do" --socket $t.socket)
            bus-send "impl-a" --run "run-1" --payload {stage: "work-do", task: "t1"}
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            let got = (bus-wait --run "run-1")
            bus-ack --run "run-1" --uid "impl-a" --sequence $got.sequence
            worker-inspect "impl-a" --run "run-1"
            run-workers "run-1"
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            sleep 400ms

            assert-eq (pane-text $t.socket "bystander") $before "no verb in the pipeline writes to another pane"
            assert-true ("bystander" in (^tmux -L $t.socket list-windows -a -F "#{window_name}" | lines)) "and the bystander window survives an acceptance"
        }
    })

    (run-case "live/acceptance-closes-only-the-worker-window" {
        with-server "scoped" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "work-do" --socket $t.socket)
            let other = (worker-spawn --run "run-1" --uid "rev-a" --role "rev" --subject "t2" --project "dotfiles" --repo $repo --task "t2" --session "sid-2" --skill "work-audit" --socket $t.socket)
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket

            let windows = (^tmux -L $t.socket list-windows -a -F "#{window_name}" | lines)
            assert-true (not ($w.window in $windows)) "the accepted worker's window is closed"
            assert-true ($other.window in $windows) "its sibling is untouched"
            assert-true ("main" in $windows) "as is the seed window"
        }
    })

    (run-case "live/a-dead-window-does-not-make-a-worker-cleanable" {
        # A missing window is missing evidence, not proof the work is done.
        # The worktree must survive, because it may hold the only copy.
        with-server "dead" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "work-do" --socket $t.socket)
            ^tmux -L $t.socket kill-window -t $w.window

            assert-eq (worker-live? $w.window --socket $t.socket) false "the window is gone"
            assert-rejects {
                worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            } "running" "a worker that never reported cannot be accepted just because its window died"
            assert-true ($w.cwd | path exists) "and its worktree survives"
        }
    })
]

$cases | to json
