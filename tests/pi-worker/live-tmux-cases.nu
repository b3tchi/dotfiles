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
    let socket = (new-tmux-socket $"t6-($tag)")
    let sandbox = ([(fixture-base) $"piw-t6-bin-($tag)-(random chars --length 6)"] | path join)
    mkdir $sandbox
    $"#!/bin/bash\n($stub)\n" | save -f ($sandbox | path join "pi")
    chmod +x ($sandbox | path join "pi")
    ^tmux -L $socket new-session -d -s "dotfiles" -n "main"
    {socket: $socket, bin: $sandbox}
}

# Wait for a pane to report dead. The stub exits immediately, but tmux updates
# `pane_dead` asynchronously, so asserting straight after spawn races it.
def wait-for-dead [socket: string, window: string, --deadline: duration = 15sec] {
    # Was a fixed 50 x 100ms with a message that named the window and nothing
    # else — so when it did time out on a loaded box, the report said only
    # that it had, not what tmux was reporting instead. A probe that fails
    # without saying what it saw ends an investigation rather than directing
    # it (adr0017's second obligation).
    let give_up = ((date now) + $deadline)
    mut last = "never answered"
    loop {
        let dead = (do { ^tmux -L $socket list-panes -t $window -F "#{pane_dead}" } | complete)
        if $dead.exit_code == 0 {
            $last = ($dead.stdout | lines | first | default "" | str trim)
            if $last == "1" { return }
        } else {
            $last = $"tmux exit ($dead.exit_code): ($dead.stderr | str trim)"
        }
        if (date now) >= $give_up {
            error make {msg: $"pane for ($window) never reported dead within ($deadline). pane_dead last read as: ($last)"}
        }
        sleep 50ms
    }
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

# Wait until a pane stops changing, and return what it settled on.
#
# Every flaky case in this suite did `sleep 600ms` and then snapshotted a
# pane. That is a bet on how long nushell takes to draw a prompt, and on a
# loaded machine it loses: the baseline gets captured mid-draw, the rest of
# the prompt arrives afterwards, and a case asserting "nothing changed" sees
# the prompt finish and calls it an injection.
#
# The honest baseline is not "after a while" but "once it has stopped moving".
def settled-pane-text [
    socket: string
    target: string
    --quiet: duration = 300ms      # unchanged for this long counts as settled
    --deadline: duration = 15sec
    # No return-type annotation: nu will not type-check a `loop` whose exits
    # are `return`s against one.
] {
    let give_up = ((date now) + $deadline)
    mut last = (pane-text $socket $target)
    mut since = (date now)
    loop {
        sleep 50ms
        let seen = (pane-text $socket $target)
        if $seen != $last {
            $last = $seen
            $since = (date now)
        } else if ($last | str trim | is-not-empty) and (((date now) - $since) >= $quiet) {
            # An EMPTY pane is not a settled one — it is a shell that has not
            # drawn anything yet, and on this box nushell can take longer than
            # the quiet period to produce its first byte. Accepting empty as
            # settled was the first version of this helper, and it turned the
            # race it was written to remove into the same race with better
            # error text: the baseline came back "", the prompt arrived after,
            # and the case reported the prompt as an injection.
            return $last
        }
        if (date now) >= $give_up {
            error make {msg: $"pane ($target) never showed settled content within ($deadline). Last read: '(($last | str substring 0..160))'"}
        }
    }
}

# Assert a pane does not change, for a while.
#
# Strictly stronger than sleeping once and comparing. A single late sample can
# miss an injection that lands before it and after the sleep; sampling
# throughout the window catches anything that appears at any point in it. It
# also degrades the right way under load — a slow machine takes MORE samples,
# not a later one.
def assert-pane-unchanged [
    socket: string
    target: string
    before: string
    --watch: duration = 1500ms
] {
    let until = ((date now) + $watch)
    loop {
        let seen = (pane-text $socket $target)
        if $seen != $before {
            error make {msg: $"pane ($target) changed, where nothing may be written.\n  before: (($before | str substring 0..200))\n  after:  (($seen | str substring 0..200))"}
        }
        if (date now) >= $until { return }
        sleep 100ms
    }
}

# A stub `pi` that runs briefly and then exits with a given code.
#
# The pause is load-bearing, not padding. `remain-on-exit` cannot be set
# atomically with `new-window` — tmux has no flag for it, and `-d` leaves the
# active window unchanged so a following `set-option` with no target would hit
# the wrong window — so worker-spawn sets it on the very next line and says so
# in a comment. A stub that exits in that same instant races a gap the product
# cannot close, and tmux destroys the window before anything can ask about it.
#
# That is not theoretical. Four cases here used a bare `exit N`, and under load
# one of them failed with
#
#     pane_dead last read as: tmux exit 1: can't find window: impl-t1@dotfiles
#
# — the window was gone, not undead, so no amount of waiting could have helped.
# It took a better error message to see that, having first tried a longer
# timeout.
#
# What these cases are for is the contract: a worker whose process dies is
# observably not running, and its window stays for inspection. The width of
# tmux's gap is not the subject.
def dies-with [code: int]: nothing -> string {
    $"sleep 0.4; exit ($code)"
}

# A stub `pi` that records its argv and then stays up.
#
# The two Pi session flags are not aliases — `--session` resumes an existing
# session, `--session-id` creates one with that id — and using the resuming one
# on a fresh session killed a pane at startup while spawn still reported
# live: true. The distinction is only observable in what the product actually
# executed, so the stub writes it down.
def records-argv [log: string]: nothing -> string {
    $"echo \"$@\" >> '($log)'\nsleep 30"
}

def argv-log [tag: string]: nothing -> string {
    ([(fixture-base) $"piw-argv-($tag)-(random chars --length 6).log"] | path join)
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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)

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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            ^tmux -L $t.socket kill-window -t $w.window

            # Something else now occupies the slot the worker had.
            ^tmux -L $t.socket new-window -d -t "dotfiles" -n "someone-elses-shell" $nu.current-exe
            let before = (settled-pane-text $t.socket "someone-elses-shell")

            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "tests green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            assert-pane-unchanged $t.socket "someone-elses-shell" $before
            let after = (pane-text $t.socket "someone-elses-shell")
            for trace in ["complete" "tests green" "sid-1" "impl-a"] {
                assert-true (not ($after | str contains $trace)) $"'($trace)' leaked into a pane"
            }

            # And the completion did arrive — at the run-scoped waiter.
            let got = (legacy-bus-wait --run "run-1")
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
            let before = (settled-pane-text $t.socket "bystander")

            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            legacy-inbox-send "impl-a" --run "run-1" --payload {stage: "wk-build", task: "t1"}
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            let got = (legacy-bus-wait --run "run-1")
            legacy-bus-ack --run "run-1" --uid "impl-a" --sequence $got.sequence
            worker-inspect "impl-a" --run "run-1"
            run-workers "run-1"
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket

            assert-pane-unchanged $t.socket "bystander" $before
            assert-true ("bystander" in (^tmux -L $t.socket list-windows -a -F "#{window_name}" | lines)) "and the bystander window survives an acceptance"
        }
    })

    (run-case "live/acceptance-closes-only-the-worker-window" {
        with-server "scoped" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            let other = (worker-spawn --run "run-1" --uid "rev-a" --role "rev" --subject "t2" --project "dotfiles" --repo $repo --task "t2" --session "sid-2" --skill "wk-review" --isolation "worktree" --socket $t.socket)
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

    # ------------------------------------------------------ release on ack
    #
    # A worker that has reported is done working, and until something accepted
    # it it went on holding a pi process and a tmux window: 29 workers were
    # doing precisely that on this box, one per smoke run. `ack` is the
    # initiator saying it HAS the result, which is the moment the display
    # resources stop having a purpose. The worktree, the branch and the
    # identity envelope stay — the work is in the first two and the session id
    # in the third.

    (run-case "live/ack-releases-the-worker-that-reported" {
        with-server "ack-release" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            assert-eq (worker-liveness $w.window_id --socket $t.socket | get verdict) "live" "still running before the ack"

            let out = (legacy-bus-ack --run "run-1" --uid "impl-a" --sequence 1 --socket $t.socket)
            assert-eq $out.released true "the report says it released the worker"
            assert-eq (worker-liveness $w.window_id --socket $t.socket | get verdict) "gone" "window and process are gone"
            # Everything a restore needs survives.
            assert-true ($w.cwd | path exists) "the worktree is untouched — it holds the work"
            assert-true ((git-in $repo "branch" "--list" $w.branch) | is-not-empty) "so is the branch"
            assert-eq (bus-identity-of "impl-a" --run "run-1" | get session) "sid-1" "and the session id"
            # The state is the worker's own last word, not a consequence of
            # being released: `complete` still means it reported complete.
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "complete" ""
        }
    })

    (run-case "live/a-second-ack-is-not-an-error" {
        # Idempotent for the same reason stop is: an initiator that retries
        # after a crash must not be told it did something illegal, and there is
        # no window left to kill the second time.
        with-server "ack-twice" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            legacy-bus-ack --run "run-1" --uid "impl-a" --sequence 1 --socket $t.socket
            let again = (legacy-bus-ack --run "run-1" --uid "impl-a" --sequence 1 --socket $t.socket)
            assert-eq $again.released false "nothing left to release"
            assert-true ($again.reason | str contains "gone") $"the reason should say why: ($again.reason)"
        }
    })

    (run-case "live/an-ack-still-acks-when-tmux-cannot-be-reached" {
        # The ack is a BUS fact and the release is a display side effect. A
        # display host that cannot be reached must not cost the initiator its
        # delivery receipt, or `wait` will hand it the same envelope forever.
        with-server "ack-notmux" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            let out = (legacy-bus-ack --run "run-1" --uid "impl-a" --sequence 1 --socket $"($t.socket)-nowhere")
            assert-eq $out.released false ""
            assert-true ($out.reason | str contains "could not") $"the reason should name the failure: ($out.reason)"
            # The receipt is what matters: the envelope must not be redelivered.
            assert-true ((legacy-bus-wait --run "run-1") == null) "an acked result is not redelivered"
            assert-eq (worker-liveness $w.window_id --socket $t.socket | get verdict) "live" "and the worker is untouched"
        }
    })

    (run-case "live/respawn-lands-back-in-the-tree-a-released-worker-left" {
        # The point of releasing early: the work is still on disk, so bringing
        # the worker back must land IN it rather than allocating a fresh
        # iteration beside it.
        with-server "ack-respawn" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            # Committed, because reporting `complete` with a dirty tree is
            # refused by the stage gate — and rightly: an uncommitted branch
            # merges as a no-op.
            "work\n" | save -f ($w.cwd | path join "work.txt")
            ^git -C $w.cwd add -A
            ^git -C $w.cwd commit -q -m "the work a respawn must land back on"
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            legacy-bus-ack --run "run-1" --uid "impl-a" --sequence 1 --socket $t.socket

            let back = (worker-respawn "impl-a" --run "run-1" --repo $repo --socket $t.socket)
            assert-eq $back.cwd $w.cwd "back in the same directory"
            assert-eq $back.branch $w.branch "on the same branch"
            assert-eq $back.reused_branch true ""
            assert-true (($back.cwd | path join "work.txt") | path exists) "with the work still in it"
            assert-eq $back.session "sid-1" "and the same transcript"
        }
    })

    # sp029 T8: "live/rejections-are-counted-along-the-respawn-lineage"
    # retired along with rejection counting and `escalate` — see
    # `worker-resume` and `worker-inspect`. Resume is now an ordinary send.
    # (The `reopened` marker itself survives — see the comment on
    # `worker-resume` and pipeline-cases.nu's "reopened-*" tests — but nothing
    # here exercised that; this test was purely about the retired count.)

    # ------------------------------------------------------------- respawn
    #
    # `accept` reclaims a verified worker's window, tree and branch and keeps
    # its identity envelope — so the session id, which is the whole of what a
    # restore needs, outlives the resources. What was missing was the way back:
    # `resume` writes a rejection into an inbox, and on a reclaimed worker no
    # process is reading it. Respawn is that way back, and it mints a NEW uid
    # rather than reviving the old one: `accepted` records that the work was
    # taken, and a state nothing leaves is worth more than one address.

    (run-case "live/respawn-continues-the-accepted-workers-session-under-a-new-uid" {
        let log = (argv-log "respawn")
        with-server "respawn" --stub (records-argv $log) {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            assert-true (not ($w.cwd | path exists)) "acceptance reclaimed the tree"

            let back = (worker-respawn "impl-a" --run "run-1" --repo $repo --socket $t.socket)
            assert-eq $back.from "impl-a" "the report says who it continues"
            assert-true ($back.uid != "impl-a") "a new address, because accepted is terminal"
            assert-eq $back.session "sid-1" "and the SAME Pi session, so the transcript continues"
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "accepted" "the old worker is left as it was"
            assert-eq (bus-status $back.uid --run "run-1" | get state) "created" "the new one has said nothing yet"

            let identity = (bus-identity-of $back.uid --run "run-1")
            assert-eq $identity.session "sid-1" ""
            assert-eq ($identity | get -o respawned_from) "impl-a" "the lineage is on the bus, not only in the report"
            assert-eq (worker-liveness $back.window_id --socket $t.socket | get verdict) "live" "and it is actually running"

            # The flag distinction, read off what was executed: the first
            # window CREATED the session, the second RESUMED it.
            #
            # The stub appends to $log ASYNCHRONOUSLY from inside its own tmux
            # window (records-argv: `echo "$@" >> log; sleep 30`) — reading
            # right after worker-respawn returns races that append. dotfiles-
            # y2np: one missing line collapses `first` and `last` onto the
            # same line, producing two different failure messages depending on
            # which one landed first.
            # The stub has not necessarily written $log AT ALL yet by the time
            # this poll starts — `open` on a not-yet-created file throws,
            # which would abort the wait instead of letting it keep polling.
            wait-until {|| (if ($log | path exists) { open $log | lines | where {|l| $l | str contains "sid-1" } | length } else { 0 }) >= 2 } --timeout 10sec --interval 50ms --what $"($log) to record both the spawn and respawn argv lines for sid-1"
            let argv = (open $log | lines | where {|l| $l | str contains "sid-1" })
            assert-true (($argv | first) | str contains "--session-id sid-1") $"spawn must create the session, got ($argv)"
            assert-true (($argv | last) | str contains "--session sid-1") $"respawn must resume it, got ($argv)"
            assert-true (not (($argv | last) | str contains "--session-id")) "and resuming is not creating"
        }
        rm -f $log
    })

    (run-case "live/respawn-reuses-the-branch-when-it-still-exists" {
        # A stopped worker keeps its branch (it may hold unmerged commits) and
        # `reclaim` takes only the directory. Coming back must land on the same
        # ref: forking a new one off base would silently drop the work.
        with-server "respawn-branch" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            "work\n" | save -f ($w.cwd | path join "work.txt")
            ^git -C $w.cwd add -A
            ^git -C $w.cwd commit -q -m "work nobody merged"
            worker-stop "impl-a" --run "run-1" --socket $t.socket
            worktrees-reclaim --repo $repo --socket $t.socket
            assert-true (not ($w.cwd | path exists)) "the tree is gone"
            assert-true ((git-in $repo "branch" "--list" $w.branch) | is-not-empty) "the ref is not"

            let back = (worker-respawn "impl-a" --run "run-1" --repo $repo --socket $t.socket)
            assert-eq $back.branch $w.branch "back on the branch that holds the work"
            assert-eq $back.reused_branch true ""
            assert-true ($back.cwd | path exists) "with a tree to work in"
            assert-eq (git-in $back.cwd "rev-parse" "--abbrev-ref" "HEAD" --) $w.branch ""
            assert-true (($back.cwd | path join "work.txt") | path exists) "and the commits are there"
        }
    })

    (run-case "live/respawn-forks-a-fresh-branch-when-the-old-one-was-reclaimed" {
        # An accepted worker's branch is deleted because it was merged, so the
        # work is in the base. Reconstructing off base is then the honest
        # answer, and the report says which happened.
        with-server "respawn-fork" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "green"
                window: $w.window, session: "sid-1", resume: "pi --session sid-1"
            }
            worker-accept "impl-a" --run "run-1" --repo $repo --socket $t.socket
            assert-true ((git-in $repo "branch" "--list" $w.branch) | is-empty) "acceptance took the ref too"

            let back = (worker-respawn "impl-a" --run "run-1" --repo $repo --socket $t.socket)
            assert-eq $back.reused_branch false "the ref was not reused, it was minted"
            assert-true ($back.cwd | path exists) ""
            # Allocation hands out the lowest free iteration, so the NAME can
            # be the deleted one's again — which is why the report answers from
            # the decision rather than from a name comparison. What matters is
            # where the ref points: at base, where the accepted work now lives.
            let base_head = (git-in $repo "rev-parse" "HEAD" --)
            assert-eq (git-in $back.cwd "rev-parse" "HEAD" --) $base_head "forked off base"
        }
    })

    (run-case "live/respawn-refuses-while-the-worker-is-still-running" {
        # Respawning a live worker would put two Pi processes on one session
        # and one transcript. The window it already has is the answer.
        with-server "respawn-live" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            assert-rejects {
                worker-respawn "impl-a" --run "run-1" --repo $repo --socket $t.socket
            } "still live" "a running worker is not respawned"
            assert-true ($w.window_id in (^tmux -L $t.socket list-windows -a -F "#{window_id}" | lines)) "and its window is untouched"
        }
    })

    (run-case "live/respawn-refuses-an-address-with-no-identity" {
        with-server "respawn-unknown" {|t, repo|
            assert-rejects {
                worker-respawn "nobody" --run "run-1" --repo $repo --socket $t.socket
            } "no identity" "there is nothing to continue"
        }
    })

    (run-case "live/resume-refuses-a-worker-with-no-live-window-and-names-respawn" {
        # The silent failure this pairs with: resume writes a rejection into an
        # inbox, and a reclaimed worker has no process reading it. It looked
        # like feedback had been delivered.
        with-server "resume-dead" --stub (dies-with 3) {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            wait-for-dead $t.socket $w.window_id

            assert-rejects {
                worker-resume "impl-a" --run "run-1" --feedback "try again" --socket $t.socket
            } "respawn" "the refusal names the verb that can bring it back"
            assert-eq ((bus-inbox "impl-a" --run "run-1") | length) 0 "and nothing was written to a dead inbox"
        }
    })

    # ------------------------------------------------------- the corpse sweep
    #
    # `remain-on-exit on` is deliberate: a worker that died at startup keeps
    # its window so the error stays readable. Nothing ever reaps those, so they
    # pile up — 23 dead worker windows were listed in this repo's session group
    # after one round of smoke tests, which is the leftover an operator sees
    # long before they notice the disk.

    (run-case "live/reclaim-reaps-a-dead-worker-window" {
        with-server "gc-dead" --stub (dies-with 3) {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            wait-for-dead $t.socket $w.window_id

            let got = (worktrees-reclaim --repo $repo --socket $t.socket)
            assert-true $got.tmux_reachable "tmux answered"
            assert-eq $got.windows_killed [$w.window_id] "the corpse is reaped"
            let windows = (^tmux -L $t.socket list-windows -a -F "#{window_id}" | lines)
            assert-true (not ($w.window_id in $windows)) "and it is gone from the window list"
            let names = (^tmux -L $t.socket list-windows -a -F "#{window_name}" | lines)
            assert-true ("main" in $names) "the seed window is untouched"
        }
    })

    (run-case "live/reclaim-leaves-a-running-workers-window-and-names-it" {
        # The other half of the observed incident: after the trees were swept,
        # two pi processes were still running and nothing said so. A sweep that
        # kills a live worker's window destroys work; one that says nothing
        # about it leaves an operator with orphans they cannot see.
        with-server "gc-alive" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)

            let got = (worktrees-reclaim --repo $repo --socket $t.socket)
            assert-eq $got.windows_killed [] "a live window is never reaped"
            assert-true ($w.window_id in (^tmux -L $t.socket list-windows -a -F "#{window_id}" | lines)) ""
            assert-eq ($got.windows_kept | first | get reason) "run-1/impl-a is still running" "and the report names who is in it"
        }
    })

    (run-case "live/a-session-group-does-not-multiply-the-sweep" {
        # `list-windows -a` reports every window once per session MEMBER, and a
        # worker window is created in a GROUP so the operator sees it whichever
        # member they are looking at. This repo's group has eleven members, so
        # the first cut of the report claimed 242 windows to reap where there
        # were 22, and would have issued eleven kills for each.
        with-server "gc-group" --stub (dies-with 3) {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            wait-for-dead $t.socket $w.window_id
            # Two more views onto the same window list.
            ^tmux -L $t.socket new-session -d -t "dotfiles" -s "dotfiles_2"
            ^tmux -L $t.socket new-session -d -t "dotfiles" -s "dotfiles_3"

            let got = (worktrees-reclaim --repo $repo --socket $t.socket --dry-run)
            assert-eq $got.windows_killed [$w.window_id] "one window, named once"
        }
    })

    (run-case "live/a-dead-window-with-no-bus-record-is-named-not-killed" {
        # Observed after the first real sweep: @232 and @234 were dead worker
        # windows whose bus records were gone, so nothing matched them and
        # nothing mentioned them either. A bus record is what proves a window
        # belongs to this project — a session group can be shared — so the
        # sweep reports these and leaves them, rather than killing on a guess
        # or staying silent about them.
        with-server "gc-noident" {|t, repo|
            # A real worker first: its window name is what tells the sweep which
            # project's naming to recognise. With no workers at all there is no
            # known project, and the sweep says nothing rather than guessing at
            # window names.
            worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket
            # A bare `exit 3` races the same tmux gap `dies-with` exists to
            # avoid (see its comment above): if the shell exits before the
            # NEXT `set-option` line runs, remain-on-exit was never on and
            # tmux destroys the window outright, which is what made this case
            # flake at roughly 1/3 independent of load.
            ^tmux -L $t.socket new-window -d -n "impl-stray@dotfiles" -t "dotfiles" $"sh -c '(dies-with 3)'"
            ^tmux -L $t.socket set-option -t "impl-stray@dotfiles" remain-on-exit on
            # remain-on-exit has to be set BEFORE the process exits to hold the
            # window, so the pane is re-run once the option is on.
            ^tmux -L $t.socket respawn-pane -k -t "impl-stray@dotfiles" $"sh -c '(dies-with 3)'"
            wait-for-dead $t.socket "impl-stray@dotfiles"

            let got = (worktrees-reclaim --repo $repo --socket $t.socket)
            assert-eq $got.windows_killed [] "a window the bus cannot vouch for is not killed"
            let named = ($got.windows_kept | where {|w| $w.reason | str contains "no identity on the bus" })
            assert-eq ($named | length) 1 $"the stray window must be reported, got ($got.windows_kept)"
            let names = (^tmux -L $t.socket list-windows -a -F "#{window_name}" | lines)
            assert-true ("impl-stray@dotfiles" in $names) "and it is still there for the operator to look at"
        }
    })

    (run-case "live/a-sweep-with-no-tmux-says-so-rather-than-reporting-no-windows" {
        # Absence of evidence is not evidence of absence (adr0017). A sweep run
        # where tmux cannot be reached must not report an empty window list as
        # though it had looked.
        with-server "gc-notmux" {|t, repo|
            worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket

            let got = (worktrees-reclaim --repo $repo --socket $"($t.socket)-nowhere")
            assert-eq $got.tmux_reachable false "the report says the probe could not be made"
            assert-eq $got.windows_killed [] "and nothing was reaped on a guess"
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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)

            assert-eq (worker-liveness $w.window --socket $t.socket | get verdict) "live" "its process is running"
            assert-eq (worker-live? $w.window --socket $t.socket) true ""
        }
    })

    (run-case "live/a-window-whose-process-exited-reports-exited-not-live" {
        # The worker's OWN evidence about ITSELF: the process it was given ran
        # and stopped. Per adr0017 that is reportable, unlike an absent window.
        with-server "verdict-exited" --stub (dies-with 3) {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
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
        with-server "verdict-noclean" --stub (dies-with 1) {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
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
        with-server "verdict-spawn" --stub (dies-with 127) {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
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
        with-server "verb" --stub (dies-with 5) {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            wait-for-dead $t.socket $w.window

            # sp029 T9: `liveness` no longer takes --run — a uid is looked up
            # wherever this user's placement record last recorded it.
            let out = (^$nu.current-exe (repo-root $env.FILE_PWD | path join "claude" "marketplace" "plugins" "pi-workers" "scripts" "pi-worker.nu") "liveness" "impl-a" "--socket" $t.socket | complete)
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

            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)

            assert-eq $w.window "impl-t1@dotfiles" "the window is named for the GROUP, which is what an operator scans for"
            assert-eq (worker-liveness $w.window --socket $t.socket | get verdict) "live" "and it really started"
        }
    })

    (run-case "live/an-exact-session-name-still-resolves" {
        # Naming one session directly must keep working: it is unambiguous, and
        # it is what an operator reaches for when a group has many views.
        with-server "exact" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
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
                worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "nosuchproject" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket
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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)

            assert-true ($w.window_id | str starts-with "@") $"a tmux window id looks like @N, got ($w.window_id)"
            let recorded = (worker-inspect "impl-a" --run "run-1" | get identity.window_id)
            assert-eq $recorded $w.window_id "and it is on the bus, so a restarted initiator can still address it"
        }
    })

    (run-case "live/two-workers-sharing-a-name-are-independently-addressable" {
        # The exact shape that broke: same role, same subject, different runs.
        with-server "collide" {|t, repo|
            let a = (worker-spawn --run "run-a" --uid "w1" --role "rev" --subject "demo" --project "dotfiles" --repo $repo --task "demo" --session "sid-a" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            let b = (worker-spawn --run "run-b" --uid "w1" --role "rev" --subject "demo" --project "dotfiles" --repo $repo --task "demo" --session "sid-b" --skill "wk-build" --isolation "worktree" --socket $t.socket)

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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1.4" --project "dotfiles" --repo $repo --task "t1.4" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            # The dot no longer reaches the window name at all: slugify-subject
            # turns it into a separator, which is a stronger fix than tolerating
            # it and addressing around it. The ticket is still recognisable in a
            # window list, and the BRANCH keeps the id exactly — that comes from
            # --task, which is an id and is never mangled to fit.
            assert-eq $w.window "impl-t1-4@dotfiles" "the display name is a name"
            assert-eq $w.branch "wk-t1.4.0" "and the branch carries the ticket id verbatim"
            # Addressing by id remains the mechanism, because a NAME is
            # ambiguous the moment two runs share a role and subject.
            assert-eq (worker-liveness $w.window_id --socket $t.socket | get verdict) "live" "liveness works by id"

            worker-stop "impl-a" --run "run-1" --socket $t.socket
            let names = (^tmux -L $t.socket list-windows -a -F "#{window_name}" | lines | each {|x| $x | str trim })
            assert-true (not ($w.window in $names)) "and the window is actually closed, not orphaned"
        }
    })

    (run-case "live/an-identity-without-a-window-id-still-resolves-by-name" {
        # Identities written before ids were recorded must not become
        # unaddressable: absent evidence is not a reason to strand a worker.
        with-server "legacy" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
            assert-eq (worker-liveness $w.window --socket $t.socket | get verdict) "live" "a name still resolves"
        }
    })

    (run-case "live/a-dead-window-does-not-make-a-worker-cleanable" {
        # A missing window is missing evidence, not proof the work is done.
        # The worktree must survive, because it may hold the only copy.
        with-server "dead" {|t, repo|
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)
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
            let w = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree" --socket $t.socket)

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
