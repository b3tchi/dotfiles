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
use ../../claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu *

# `--stub` is the body of the fake `pi`. The default outlives a case; a case
# that needs a DEAD worker passes something that exits, which is the only way
# to exercise a pane that spawn's `remain-on-exit on` keeps listed after its
# process is gone (dotfiles-yii5).
def make-server [tag: string, --stub: string = "sleep 30"]: nothing -> record {
    let socket = $"piw-t6-($tag)-(random chars --length 6)"
    let sandbox = ([$nu.temp-dir $"piw-t6-bin-($tag)-(random chars --length 6)"] | path join)
    mkdir $sandbox
    $"#!/bin/bash\n($stub)\n" | save -f ($sandbox | path join "pi")
    chmod +x ($sandbox | path join "pi")
    ^tmux -L $socket new-session -d -s "dotfiles" -n "main"
    {socket: $socket, bin: $sandbox}
}

# Wait for a pane to report dead. The stub exits immediately, but tmux updates
# `pane_dead` asynchronously, so asserting straight after spawn races it.
def wait-for-dead [socket: string, window: string] {
    for _ in 0..50 {
        let dead = (do { ^tmux -L $socket list-panes -t $window -F "#{pane_dead}" } | complete)
        if ($dead.exit_code == 0) and (($dead.stdout | lines | first | str trim) == "1") { return }
        sleep 100ms
    }
    error make {msg: $"pane for ($window) never reported dead"}
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

def with-server [tag: string, body: closure, --stub: string = "sleep 30"] {
    let t = (make-server $tag --stub $stub)
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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)

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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
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

            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            bus-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t1"}
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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            let other = (worker-spawn --run "run-1" --uid "rev-a" --role "rev" --subject "t2" --project "dotfiles" --repo $repo --task "t2" --session "sid-2" --skill "wk-review" --socket $t.socket)
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

    # ------------------------------------------------------------- liveness
    #
    # dotfiles-yii5: `worker-live?` matched on the window NAME alone. spawn
    # sets `remain-on-exit on` deliberately, so a worker whose process died at
    # startup keeps its window listed forever — and spawn reported live: true
    # for a worker that never ran. That is how the --session/--session-id bug
    # (dotfiles-4xtz) stayed invisible: every worker was dead and the tool said
    # they were fine.
    #
    # adr0017 governs the shape of the fix. "I cannot tell" is a first-class
    # verdict, distinct from "it is dead", and absence of evidence must never
    # be encoded as evidence of absence. A bool cannot say both, so the probe
    # returns three verdicts and the bool means strictly "observably running".

    (run-case "live/a-running-worker-is-live" {
        with-server "verdict-live" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)

            assert-eq (worker-liveness $w.window --socket $t.socket | get verdict) "live" "its process is running"
            assert-eq (worker-live? $w.window --socket $t.socket) true ""
        }
    })

    (run-case "live/a-window-whose-process-exited-reports-exited-not-live" {
        # The worker's OWN evidence about ITSELF: the process it was given ran
        # and stopped. Per adr0017 that is reportable, unlike an absent window.
        with-server "verdict-exited" --stub "exit 3" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            wait-for-dead $t.socket $w.window

            let seen = (worker-liveness $w.window --socket $t.socket)
            assert-eq $seen.verdict "exited" "a dead pane is observably not running"
            assert-eq (worker-live? $w.window --socket $t.socket) false "so it is not live"
            let listed = (^tmux -L $t.socket list-windows -a -F "#{window_name}" | lines | each {|x| $x | str trim })
            assert-true ($w.window in $listed) "though remain-on-exit keeps the window for inspection"
        }
    })

    (run-case "live/a-missing-window-is-gone-not-unknown-and-not-exited" {
        # This case used to expect `unknown`, on the reasoning that "nobody
        # watched this worker stop". That reasoning was wrong here: tmux WAS
        # asked, and answered that the window does not exist. Absence of the
        # window is a finding.
        #
        # Sharing one verdict with "tmux could not be reached" is the bug
        # adr0017 names in its own consequences — "sharing a code between
        # 'dead' and 'cannot tell' is precisely the bug this prevents". It cost
        # a real worker: reaped mid-task, its window gone, and because
        # `unknown` correctly never licenses cleanup, the bus left it `running`
        # for five minutes with nothing able to move it.
        #
        # `exited` is still wrong — that means the pane survived and its
        # process did not, which is the worker's own evidence about itself.
        # The genuinely unobservable case is the next one along.
        with-server "verdict-gone" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            ^tmux -L $t.socket kill-window -t $w.window

            let seen = (worker-liveness $w.window --socket $t.socket)
            assert-eq $seen.verdict "gone" "tmux answered: there is no such window"
            assert-true ($seen.reason | str contains "no such window") "and says which finding it is"
            assert-eq (worker-live? $w.window --socket $t.socket) false "not live either way"
        }
    })

    (run-case "live/an-unreachable-tmux-server-is-unknown-not-a-dead-worker" {
        # The caller's own failure to reach tmux says nothing about the worker.
        # adr0017: "a caller's missing X authority must never read as a dead
        # server" — same shape, same rule.
        let seen = (worker-liveness "impl-a@dotfiles" --socket "piw-t6-no-such-server")
        assert-eq $seen.verdict "unknown" "we could not look, so we do not know"
    })

    (run-case "live/an-exited-worker-is-still-not-cleanable" {
        # Knowing a process stopped is not knowing the work is finished. The
        # verdict is reportable; it licenses nothing.
        with-server "verdict-noclean" --stub "exit 1" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            wait-for-dead $t.socket $w.window

            assert-rejects {
                worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            } "created" "an exited worker that never reported cannot be accepted"
            assert-true ($w.cwd | path exists) "and its worktree survives"
        }
    })

    (run-case "live/spawn-does-not-claim-a-worker-is-live-when-it-died-at-startup" {
        # The regression this whole issue is about. A worker whose command is
        # wrong dies immediately, and spawn must say so rather than report
        # health it did not observe.
        with-server "verdict-spawn" --stub "exit 127" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            wait-for-dead $t.socket $w.window

            assert-eq (worker-liveness $w.window --socket $t.socket | get verdict) "exited" "the pane is dead"
            # spawn's own record is a snapshot taken before the process could
            # fail, so it may legitimately read live: true. What must NOT
            # happen is a later probe agreeing with that stale snapshot.
            assert-eq (worker-live? $w.window --socket $t.socket) false "a fresh probe reports the truth"
        }
    })

    (run-case "live/the-liveness-verb-answers-for-a-worker-by-uid" {
        # The operator-facing half of dotfiles-yii5. Being told `live: true` at
        # spawn and having no way to ask again later is how a whole run of dead
        # workers went unnoticed. `inspect` cannot answer this — it is
        # deliberately bus-only, so that a restarted initiator can rebuild a run
        # without tmux — which is exactly why the probe needs its own verb.
        with-server "verb" --stub "exit 5" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            wait-for-dead $t.socket $w.window

            let out = (^$nu.current-exe (repo-root $env.FILE_PWD | path join "claude" "marketplace" "plugins" "pi-workers" "scripts" "pi-worker.nu") "liveness" "impl-a" "--run" "run-1" "--socket" $t.socket | complete)
            assert-eq $out.exit_code 0 $"($out.stderr)"
            let seen = ($out.stdout | from json)
            assert-eq $seen.verdict "exited" "the operator can ask, and gets the truth"
            assert-eq $seen.window $w.window "about the right window"
        }
    })

    # ----------------------------------------------------- project resolution
    #
    # dotfiles-k5vt: the README documents `--project <your-group>`, and that is
    # the right mental model — grouped sessions SHARE windows, so a worker
    # window created in any session of a group appears in all of them, and
    # `<role>-<subject>@<group>` is what an operator scans for. But
    # `tmux new-window -t` takes a SESSION, so the documented command failed
    # with "can't find window: dotfiles" on a machine whose sessions are
    # dotfiles_3 .. dotfiles_36.
    #
    # The shape is the one this repo's own tmux-start produces:
    #   tmux new-session -d -t <name> -s <name>_<n>
    # The eponymous session establishes the group, later views join it, and once
    # it is gone the group has no session named after it at all.

    (run-case "live/a-session-group-name-resolves-to-one-of-its-sessions" {
        with-server "group" {|t, repo|
            # Build the real-world shape: a group with NO session of its name
            # and MORE THAN ONE member.
            #
            # Two matters. tmux `-t` prefix-matches SESSION names; it does not
            # resolve groups. With a single member `-t dotfiles` matches
            # `dotfiles_7` by accident and appears to work — which is why this
            # case first passed against the unfixed code. Add a second view and
            # the prefix is ambiguous, producing the operator-hostile
            # "can't find window: dotfiles" seen on the live run. Relying on
            # accidental uniqueness is worse than failing: it works until
            # someone opens a second view.
            ^tmux -L $t.socket new-session -d -t "dotfiles" -s "dotfiles_7"
            ^tmux -L $t.socket new-session -d -t "dotfiles" -s "dotfiles_8"
            ^tmux -L $t.socket kill-session -t "dotfiles"
            let groups = (^tmux -L $t.socket list-sessions -F "#{session_name}|#{session_group}" | lines)
            assert-true ("dotfiles_7|dotfiles" in $groups) $"fixture must be a group with no eponymous session, got ($groups)"
            assert-true ("dotfiles_8|dotfiles" in $groups) $"and more than one member, got ($groups)"

            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)

            assert-eq $w.window "impl-t1@dotfiles" "the window is named for the GROUP, which is what an operator scans for"
            assert-eq (worker-liveness $w.window --socket $t.socket | get verdict) "live" "and it really started"
        }
    })

    (run-case "live/an-exact-session-name-still-resolves" {
        # Naming one session directly must keep working: it is unambiguous, and
        # it is what an operator reaches for when a group has many views.
        with-server "exact" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            assert-eq $w.window "impl-t1@dotfiles" ""
            assert-eq (worker-liveness $w.window --socket $t.socket | get verdict) "live" ""
        }
    })

    (run-case "live/an-unknown-project-is-refused-before-anything-is-allocated" {
        # The first live run hit this: a wrong --project failed at new-window,
        # AFTER the worktree and identity envelope had been written, leaving a
        # wk-sp028.0 branch to prune by hand. Resolution now happens before any
        # allocation, so a typo costs nothing.
        with-server "nogroup" {|t, repo|
            assert-rejects {
                worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "nosuchproject" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket
            } "nosuchproject" "the refusal must name what could not be found"

            assert-true (not (($repo | path join ".worktrees" "wk-t1.0") | path exists)) "and allocate nothing"
            let branches = (^git -C $repo branch --list "wk-*" | str trim)
            assert-eq $branches "" $"nor leave a branch behind, got ($branches)"
        }
    })

    # ------------------------------------------------- addressing by window id
    #
    # dotfiles-idzp: `<role>-<subject>@<project>` carries nothing identifying
    # the run or the worker, so two workers with the same role and subject in
    # different runs got identical window names. Observed live: three stopped
    # workers reported `live` because the probe matched a different worker's
    # window, and `stop` ran kill-window against an ambiguous name, closing at
    # most one and orphaning the rest. A teardown that hits the wrong worker is
    # the worst thing this transport can do.
    #
    # tmux hands out a window_id (@N) at creation. It is unique, stable, and has
    # no '.' to be misparsed — which also settles dotfiles-pnxw. The name stays
    # as the human label; every -t operation uses the id.

    (run-case "live/spawn-records-the-window-id-tmux-assigned" {
        with-server "wid" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)

            assert-true ($w.window_id | str starts-with "@") $"a tmux window id looks like @N, got ($w.window_id)"
            let recorded = (worker-inspect "impl-a" --run "run-1" | get identity.window_id)
            assert-eq $recorded $w.window_id "and it is on the bus, so a restarted initiator can still address it"
        }
    })

    (run-case "live/two-workers-sharing-a-name-are-independently-addressable" {
        # The exact shape that broke: same role, same subject, different runs.
        with-server "collide" {|t, repo|
            let a = (worker-spawn --run "run-a" --uid "w1" --role "rev" --subject "demo" --project "dotfiles" --repo $repo --task "demo" --session "sid-a" --skill "wk-build" --socket $t.socket)
            let b = (worker-spawn --run "run-b" --uid "w1" --role "rev" --subject "demo" --project "dotfiles" --repo $repo --task "demo" --session "sid-b" --skill "wk-build" --socket $t.socket)

            assert-eq $a.window $b.window "they really do share a display name"
            assert-true ($a.window_id != $b.window_id) "but not an id"

            # Stopping one must leave the other running.
            worker-stop "w1" --run "run-a" --socket $t.socket
            assert-eq (bus-status "w1" --run "run-b" | get state) "created" "the other worker is untouched"
            assert-eq (worker-liveness $b.window_id --socket $t.socket | get verdict) "live" "and still alive"
            # This assertion's own message said "gone" while expecting
            # `unknown`: the prose had the right word before the verdict
            # vocabulary did.
            assert-eq (worker-liveness $a.window_id --socket $t.socket | get verdict) "gone" "while the stopped one's window is gone"
        }
    })

    (run-case "live/a-dotted-subject-spawns-probes-and-stops-cleanly" {
        # dotfiles-pnxw. A ticket id like `dotfiles-963w.4` is the normal shape
        # for a ticket-payload stage, and tmux parses `.4` as a pane index, so
        # every -t operation against the NAME misparsed it. Addressing by id
        # sidesteps the grammar entirely.
        with-server "dotted" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1.4" --project "dotfiles" --repo $repo --task "t1.4" --session "sid-1" --skill "wk-build" --socket $t.socket)
            assert-true ($w.window | str contains ".4") "the display name keeps the real subject"
            assert-eq (worker-liveness $w.window_id --socket $t.socket | get verdict) "live" "liveness works despite the dot"

            worker-stop "impl-a" --run "run-1" --socket $t.socket
            let names = (^tmux -L $t.socket list-windows -a -F "#{window_name}" | lines | each {|x| $x | str trim })
            assert-true (not ($w.window in $names)) "and the window is actually closed, not orphaned"
        }
    })

    (run-case "live/an-identity-without-a-window-id-still-resolves-by-name" {
        # Identities written before ids were recorded must not become
        # unaddressable: absent evidence is not a reason to strand a worker.
        with-server "legacy" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            assert-eq (worker-liveness $w.window --socket $t.socket | get verdict) "live" "a name still resolves"
        }
    })

    (run-case "live/a-dead-window-does-not-make-a-worker-cleanable" {
        # A missing window is missing evidence, not proof the work is done.
        # The worktree must survive, because it may hold the only copy.
        with-server "dead" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
            ^tmux -L $t.socket kill-window -t $w.window

            assert-eq (worker-live? $w.window --socket $t.socket) false "the window is gone"
            assert-rejects {
                worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            } "created" "a worker that never reported cannot be accepted just because its window died"
            assert-true ($w.cwd | path exists) "and its worktree survives"
        }
    })
    (run-case "live/the-worker-is-launched-with-a-create-if-missing-session-flag" {
        # Pi distinguishes the two session flags:
        #   --session <path|id>  resume an EXISTING session; errors if absent
        #   --session-id <id>    use this exact id, CREATING it if missing
        #
        # spawn mints a fresh uuid, so that session cannot exist yet and
        # `--session` is always wrong there. A live run caught this: Pi printed
        # "No session found matching '<uuid>'" and exited, leaving a dead pane
        # while spawn still reported live: true (worker-live? matches on the
        # window NAME, and remain-on-exit keeps a dead window listed).
        #
        # The stub `pi` in this harness is `sleep 30`, which accepts any argv,
        # so the flag itself has to be asserted -- otherwise the suite stays
        # green while the launched command never starts.
        with-server "sessionflag" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)

            let start = (
                ^tmux -L $t.socket list-panes -a -F "#{window_name}\t#{pane_start_command}"
                | lines
                | where {|l| $l | str starts-with $"($w.window)\t" }
                | first
                | split row "\t"
                | last
            )
            assert-true ($start | str contains "--session-id") $"spawn must create-if-missing, got: ($start)"
            assert-true (not ($start | str contains "--session ")) $"a bare --session cannot resume an unborn session: ($start)"
            assert-true ($start | str contains "sid-1") $"the session id must reach pi: ($start)"

            # Resume is the opposite case: by then the session exists, so the
            # documented resume command is the plain --session form.
            assert-eq $w.resume "pi --session sid-1" "the resume hint resumes rather than creates"
        }
    })
]

$cases | to json
