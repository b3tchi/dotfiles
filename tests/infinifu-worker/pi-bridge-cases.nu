#!/usr/bin/env nu
# Pi spawn cases (sp028 T4).
#
# Every case runs against a PRIVATE tmux server (`tmux -L <unique>`) and a stub
# `pi` on a sandboxed PATH. Nothing here can see, signal, or tear down a real
# session — poc022 hit exactly that hazard and its recommendation was to use
# private sockets in integration tests.
#
# The decisions inside the extension (steer vs follow-up, payload shaping,
# result validation) are covered by extensions/pi.test.ts under `bun test`.
# What these cases cover is the process side: a window named the way an
# operator will look for it, in the right worktree, with identity recorded on
# the bus, and a crashed worker still visible rather than silently gone.

use harness.nu *
use ../../claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu *

# A private tmux server plus a stub `pi`. The stub is what makes the case
# hermetic: a real Pi would need a model, a network, and minutes.
def make-tmux [tag: string, pi_body: string]: nothing -> record {
    let socket = $"infinifu-t4-($tag)-(random chars --length 6)"
    let sandbox = ([$nu.temp-dir $"infinifu-t4-bin-($tag)-(random chars --length 6)"] | path join)
    mkdir $sandbox
    $"#!/bin/bash\n($pi_body)\n" | save -f ($sandbox | path join "pi")
    chmod +x ($sandbox | path join "pi")
    ^tmux -L $socket new-session -d -s "dotfiles" -n "main"
    {socket: $socket, bin: $sandbox}
}

def drop-tmux [t: record] {
    # Only ever the private server this case created.
    drop-tmux-server $t.socket
    rm -rf $t.bin
}

def windows-on [socket: string]: nothing -> list<string> {
    ^tmux -L $socket list-windows -a -F "#{window_name}" | lines | each {|w| $w | str trim }
}

# One call site for the long flag list, so each case reads as what it is
# testing rather than as argument plumbing. Named spawn-worker, not spawn:
# nushell resolves a bare `spawn` against `job spawn` and the def is shadowed.
def spawn-worker [
    t: record
    repo: string
    --skill: string = "work-do"
    --task: string = "t1"
    --socket: string = ""
    --session: string = "sid-1"
] {
    let sock = (if ($socket | is-empty) { $t.socket } else { $socket })
    worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task $task --session $session --skill $skill --socket $sock
}

let cases = [
    # ------------------------------------------------------- window identity
    (run-case "spawn/window-is-named-role-subject-at-project" {
        assert-eq (worker-window-name "impl" "dotfiles-963w.4" "dotfiles") "impl-dotfiles-963w.4@dotfiles" "the name an operator scans for"
        assert-eq (worker-window-name "rev" "sp028" "akm") "rev-sp028@akm" ""
    })

    (run-case "spawn/creates-a-named-window-in-the-project-group" {
        let repo = (make-repo "spawn")
        let root = (make-runtime "spawn")
        let t = (make-tmux "spawn" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "work-do" --socket $t.socket)
                assert-eq $got.window "impl-t1@dotfiles" ""
                assert-true ($got.window in (windows-on $t.socket)) "the window is really there"
                # The seed window is untouched: spawn adds, it does not take over.
                assert-true ("main" in (windows-on $t.socket)) "the existing session is left alone"
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/runs-in-the-allocated-worktree" {
        let repo = (make-repo "cwd")
        let root = (make-runtime "cwd")
        let t = (make-tmux "cwd" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "work-do" --socket $t.socket)
                assert-eq ($got.cwd | path basename) "bd-t1.0" "the worker starts in its own worktree"
                assert-true ($got.cwd | path exists) ""
                worktree-validate --repo $repo --path $got.cwd --branch "bd-t1.0"
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/records-identity-on-the-bus" {
        let repo = (make-repo "ident")
        let root = (make-runtime "ident")
        let t = (make-tmux "ident" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                spawn-worker $t $repo --task "t1" --session "sid-42" --skill "work-do"

                let identity = (bus-identity-of "impl-a" --run "run-1")
                assert-eq $identity.session "sid-42" "the resume handle is recorded before anything can fail"
                assert-eq $identity.window "impl-t1@dotfiles" ""
                assert-eq $identity.skill "work-do" ""
                assert-eq $identity.role "impl" ""
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/passes-the-session-id-to-pi" {
        # The stable session id is what makes a rejected worker resumable, so
        # it has to actually reach the process, not just the identity record.
        let repo = (make-repo "sid")
        let root = (make-runtime "sid")
        let marker = ([$nu.temp-dir $"infinifu-t4-argv-(random chars --length 6)"] | path join)
        let t = (make-tmux "sid" $"echo \"$@\" > ($marker); sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                spawn-worker $t $repo --task "t1" --session "sid-77" --skill "work-do"
                sleep 400ms
                let argv = (open --raw $marker)
                assert-true ($argv | str contains "--session") "pi is invoked with a session flag"
                assert-true ($argv | str contains "sid-77") "and with the stable id"
            }
        }
        rm -f $marker; drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/an-akm-stage-spawns-without-a-bd-task" {
        # AKM stages carry an artifact id, not a ticket. This path had no
        # coverage and was broken: the branch name fell back through a filter
        # that raises on a plain string, and the failure surfaced as an
        # unrelated "External command failed".
        let repo = (make-repo "akm")
        let root = (make-runtime "akm")
        let t = (make-tmux "akm" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                let got = (spawn-worker $t $repo --task "" --skill "spec-refinement" --session "sid-akm")
                assert-eq $got.window "impl-t1@dotfiles" ""
                assert-eq $got.branch "bd-t1.0" "the branch falls back to the subject, not an empty name"
                assert-true ($got.cwd | path exists) ""
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/passes-worker-identity-into-the-window-environment" {
        # The extension has to know which inbox is its own before any message
        # can arrive, so identity travels as window environment rather than as
        # a bootstrap message that would have nowhere to land.
        let repo = (make-repo "env")
        let root = (make-runtime "env")
        let marker = ([$nu.temp-dir $"infinifu-t4-env-(random chars --length 6)"] | path join)
        let t = (make-tmux "env" $"env | grep INFINIFU_ > ($marker); sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                spawn-worker $t $repo --task "t1" --session "sid-env" --skill "work-do"
                sleep 500ms
                let seen = (open --raw $marker)
                for pair in ["INFINIFU_RUN=run-1" "INFINIFU_UID=impl-a" "INFINIFU_ROLE=impl" "INFINIFU_SESSION=sid-env" "INFINIFU_SKILL=work-do" "INFINIFU_WINDOW=impl-t1@dotfiles" "INFINIFU_BRANCH=bd-t1.0"] {
                    assert-true ($seen | str contains $pair) $"the worker window carries ($pair)"
                }
            }
        }
        rm -f $marker; drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    # ------------------------------------------------------------ visibility
    (run-case "spawn/a-worker-that-exits-immediately-stays-visible" {
        # Pi exiting before it initialises must not erase the evidence. The
        # window stays so an operator can read why, and the identity is already
        # on the bus.
        let repo = (make-repo "crash")
        let root = (make-runtime "crash")
        let t = (make-tmux "crash" "echo 'pi failed to start' >&2; exit 3")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "work-do" --socket $t.socket)
                sleep 400ms
                assert-true ($got.window in (windows-on $t.socket)) "the dead worker's window is still inspectable"
                assert-eq (bus-identity-of "impl-a" --run "run-1" | get session) "sid-1" "and its identity survives"
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/reports-liveness-without-inventing-it" {
        # adr0017: spawn reports what it observed. A window that is gone is
        # reported as not live, never silently treated as running.
        let repo = (make-repo "live")
        let root = (make-runtime "live")
        let t = (make-tmux "live" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "work-do" --socket $t.socket)
                assert-eq $got.live true "a running worker reports live"

                ^tmux -L $t.socket kill-window -t $got.window
                assert-eq (worker-live? $got.window --socket $t.socket) false "a removed window reports not-live"
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/identity-survives-a-failed-window-creation" {
        # Evidence before process. If the window cannot be created, the worker
        # never runs — but its worktree and resume handle already exist, and an
        # operator needs both to clean up. Recording identity after the spawn
        # would lose exactly the information the failure makes necessary.
        let repo = (make-repo "order")
        let root = (make-runtime "order")
        let t = (make-tmux "order" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                # The server is reachable; the target session is not there, so
                # new-window fails while everything before it has succeeded.
                assert-rejects {
                    worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "no-such-session" --repo $repo --task "t1" --session "sid-o" --skill "work-do" --socket $t.socket
                } "window" "the window failure is reported"

                let identity = (bus-identity-of "impl-a" --run "run-1")
                assert-true ($identity != null) "identity was recorded before the process was started"
                assert-eq $identity.session "sid-o" "so the worker is still resumable"
                assert-true ($identity.cwd | path exists) "and its worktree can still be found and cleaned up"
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    # ------------------------------------------------------------ fail closed
    (run-case "spawn/refuses-when-tmux-cannot-be-reached" {
        # A spawn that cannot create its window must not leave a half-worker
        # behind claiming to exist.
        let repo = (make-repo "notmux")
        let root = (make-runtime "notmux")
        let t = {socket: "infinifu-t4-does-not-exist", bin: ""}
        with-runtime $root {
            assert-rejects {
                spawn-worker $t $repo --task "t1" --session "sid-1" --skill "work-do"
            } "tmux" "an unreachable tmux server is named in the failure"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/refuses-an-unknown-skill" {
        # Edge case: skill configuration that no stage recognises. Launching
        # anyway would produce a worker with no contract to follow.
        let repo = (make-repo "skill")
        let root = (make-runtime "skill")
        let t = (make-tmux "skill" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                assert-rejects {
                    spawn-worker $t $repo --task "t1" --session "sid-1" --skill "not-a-real-skill"
                } "skill" "an unknown skill is refused by name"
                assert-true (not ("impl-t1@dotfiles" in (windows-on $t.socket))) "and no window is left behind"
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/work-skill-requires-a-task-id" {
        let repo = (make-repo "notask")
        let root = (make-runtime "notask")
        let t = (make-tmux "notask" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                assert-rejects {
                    spawn-worker $t $repo --task "" --session "sid-1" --skill "work-do"
                } "task" "a work stage without a bd task id has no contract to read"
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })
]

$cases | to json
