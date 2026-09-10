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
use ../../claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu *

# A private tmux server plus a stub `pi`. The stub is what makes the case
# hermetic: a real Pi would need a model, a network, and minutes.
def make-tmux [tag: string, pi_body: string]: nothing -> record {
    let socket = (new-tmux-socket $"t4-($tag)")
    let sandbox = ([(fixture-base) $"piw-t4-bin-($tag)-(random chars --length 6)"] | path join)
    mkdir $sandbox
    $"#!/bin/bash\n($pi_body)\n" | save -f ($sandbox | path join "pi")
    chmod +x ($sandbox | path join "pi")
    ^tmux -L $socket new-session -d -s "dotfiles" -n "main"
    {socket: $socket, bin: $sandbox}
}

# A `tmux` that answers every read but REFUSES new-window, delegating the rest
# to the real binary on the private socket.
#
# The evidence-before-process case used to force its failure with a bad
# `--project`, but that is now caught up front (dotfiles-k5vt) — a caller error
# detectable before anything is allocated, so nothing is left to recover. The
# invariant it guards is about the OTHER kind of failure: tmux reachable, the
# target valid, and window creation failing anyway. Injecting that needs a
# real refusal from new-window rather than a proxy for one.
def stub-tmux-refusing-new-window [tag: string, bin: string, real: string] {
    let script = ([
        "#!/bin/bash"
        "for a in \"$@\"; do"
        "  if [ \"$a\" = new-window ]; then"
        "    echo 'create window failed: injected' >&2"
        "    exit 1"
        "  fi"
        "done"
        $"exec ($real) \"$@\""
    ] | str join "\n")
    $script | save -f ($bin | path join "tmux")
    chmod +x ($bin | path join "tmux")
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
    --skill: string = "wk-build"
    --isolation: string = "worktree"
    --task: string = "t1"
    --socket: string = ""
    --session: string = "sid-1"
] {
    let sock = (if ($socket | is-empty) { $t.socket } else { $socket })
    worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task $task --session $session --skill $skill --isolation $isolation --socket $sock
}

let cases = [
    # ------------------------------------------------------- window identity
    (run-case "spawn/window-is-named-role-subject-at-project" {
        assert-eq (worker-window-name "impl" "dotfiles-963w.4" "dotfiles") "impl-dotfiles-963w.4@dotfiles" "the name an operator scans for"
        assert-eq (worker-window-name "rev" "sp028" "akm") "rev-sp028@akm" ""
    })

    (run-case "spawn/a-subject-is-slugified-into-a-name" {
        # A subject is worn as a tmux window name AND a git branch, so it has
        # to be a name. Observed live: window @234 in this repo's group was
        # called
        #
        #     impl-Create timestamp-named text file with header in
        #     /home/jan/.dotfiles. Filename must be safe.@dotfiles
        #
        # because an agent passed its whole instruction as --subject. The
        # window list became unreadable, `.` and `/` are hostile in a branch
        # name, and worktree-allocate spent 64 attempts failing to build a ref
        # out of it.
        assert-eq (slugify-subject "timestamp-file") "timestamp-file" "a slug is already a slug"
        assert-eq (slugify-subject "Create timestamp-named text file") "create-timestamp-named-text-file" "prose becomes a name"
        assert-eq (slugify-subject "dotfiles-963w.4") "dotfiles-963w-4" "a dot is hostile in a ref and reads badly in a window list"
        assert-eq (slugify-subject "feat/add thing") "feat-add-thing" "so is a slash"
        assert-eq (slugify-subject "  spaced  out  ") "spaced-out" "no leading, trailing or doubled separators"
        assert-eq (slugify-subject "--dashes--") "dashes" ""
        # Capped, because the name has to be readable in a window list — which
        # also means cutting at a word boundary rather than at the character
        # limit: a hard cut gave `create-timestamp-named-text-file-with-he`.
        let long = (slugify-subject "Create a new text file whose filename is the current timestamp in a safe format")
        assert-true (($long | str length) <= $MAX_SUBJECT_CHARS) $"($long) is longer than ($MAX_SUBJECT_CHARS)"
        assert-true (not ($long | str ends-with "-")) $"($long) ends with a separator"
        assert-eq $long "create-a-new-text-file-whose-filename-is" "whole words only"
        # The cut STOPS at the first word that does not fit. Taking every word
        # that happens to fit produced `create-timestamp-named-text-file-with-in`
        # from "...text file with header in /home/jan/.dotfiles": `header` was
        # skipped for being too long and `in` was welded on after it, so the
        # name read as words the caller never put next to each other.
        assert-eq (
            slugify-subject "Create timestamp-named text file with header in /home/jan/.dotfiles"
        ) "create-timestamp-named-text-file-with" "no words welded across a skipped one"
        # No boundary to find: one word longer than the whole budget is cut
        # hard, because the alternative is an empty name.
        let unbroken = (slugify-subject ("z" | fill --width 60 --character "z"))
        assert-eq ($unbroken | str length) $MAX_SUBJECT_CHARS "cut hard when there is nothing to cut at"
    })

    (run-case "spawn/a-subject-with-nothing-usable-in-it-is-refused" {
        # Slugifying is not a licence to invent an address. Punctuation alone
        # leaves nothing to name a window after, and a worker called `impl-@`
        # is worse than a refusal.
        assert-rejects { slugify-subject "!!! ???" } "no usable characters" "there is no name in there"
        assert-rejects { slugify-subject "" } "no usable characters" ""
    })

    (run-case "spawn/prose-cannot-reach-a-window-name-through-the-module-either" {
        # The guard used to live in the CLI wrapper alone, so every nu caller
        # of worker-spawn — the scrum-master skill, the tests, a future verb —
        # bypassed it. Slugifying inside worker-spawn is what makes the naming
        # a property of spawning rather than of one entry point.
        let repo = (make-repo "slug-spawn")
        let root = (make-runtime "slug-spawn")
        let t = (make-tmux "slug-spawn" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                let got = (worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "Create timestamp-named text file" --project "dotfiles" --repo $repo --session "sid-1" --skill "doc-draft" --isolation "main" --socket $t.socket)
                assert-eq $got.window "impl-create-timestamp-named-text-file@dotfiles" "the window is named, not narrated"
                assert-eq $got.subject "create-timestamp-named-text-file" "and the report says what the address became"
                assert-true ($got.window in (windows-on $t.socket)) ""
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/the-cli-takes-prose-and-names-the-window-anyway" {
        # The CLI used to refuse a --subject containing whitespace. An agent
        # that had already written its instruction into the wrong flag then got
        # a lecture instead of a worker, mid-round. Now the address is derived
        # and the run continues; the instruction still has to travel by `send`.
        let repo = (make-repo "slug-cli")
        let root = (make-runtime "slug-cli")
        let t = (make-tmux "slug-cli" "sleep 30")
        let cli = (worker-script $env.FILE_PWD)
        let out = (with-env {XDG_RUNTIME_DIR: $root, PATH: ([$t.bin] ++ $env.PATH)} {
            # sp029 T9: spawn no longer takes --run — it is minted internally
            # and no longer surfaced as a flag at all.
            (^$nu.current-exe $cli spawn
                --uid "impl-a" --role "impl"
                --subject "Create timestamp-named text file with header"
                --project "dotfiles" --repo $repo
                --session "sid-1" --skill "doc-draft" --isolation "main" --socket $t.socket) | complete
        })
        assert-eq $out.exit_code 0 $"spawn refused prose: ($out.stderr | str trim)"
        let got = ($out.stdout | from json)
        assert-eq $got.subject "create-timestamp-named-text-file-with" "capped at a readable length, on a word boundary"
        assert-eq $got.window "impl-create-timestamp-named-text-file-with@dotfiles" ""
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/creates-a-named-window-in-the-project-group" {
        let repo = (make-repo "spawn")
        let root = (make-runtime "spawn")
        let t = (make-tmux "spawn" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
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
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
                assert-eq ($got.cwd | path basename) "wk-t1.0" "the worker starts in its own worktree"
                assert-true ($got.cwd | path exists) ""
                worktree-validate --repo $repo --path $got.cwd --branch "wk-t1.0"
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
                spawn-worker $t $repo --task "t1" --session "sid-42" --skill "wk-build"

                let identity = (bus-identity-of "impl-a" --run "run-1")
                assert-eq $identity.session "sid-42" "the resume handle is recorded before anything can fail"
                assert-eq $identity.window "impl-t1@dotfiles" ""
                assert-eq $identity.skill "wk-build" ""
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
        let marker = ([(fixture-base) $"piw-t4-argv-(random chars --length 6)"] | path join)
        let t = (make-tmux "sid" $"echo \"$@\" > ($marker); sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                spawn-worker $t $repo --task "t1" --session "sid-77" --skill "wk-build"
                # The stub writes $marker from inside its own tmux window,
                # asynchronously to this process. A fixed sleep is a bet on how
                # fast that write lands; poll for it instead (dotfiles-6nvx.21).
                wait-until {|| ($marker | path exists) and ((open --raw $marker | str trim) | is-not-empty) } --timeout 5sec --interval 50ms --what $"($marker) to be written by the stub pi"
                let argv = (open --raw $marker)
                assert-true ($argv | str contains "--session") "pi is invoked with a session flag"
                assert-true ($argv | str contains "sid-77") "and with the stable id"
            }
        }
        rm -f $marker; drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/an-akm-stage-spawns-in-the-main-worktree-without-a-bd-task" {
        # AKM stages carry an artifact id, not a ticket.
        #
        # This case used to assert the branch was `wk-t1.0` and the cwd an
        # isolated worktree. That was the bug (dotfiles-ptba), not the contract:
        # akm-root refuses to serve any worktree but the main one, so a worker
        # placed in `wk-t1.0` could not read or write the AKM it was spawned to
        # edit, and the guard's own advice sent it back to the main worktree
        # anyway — abandoning the isolation silently. Placement now matches what
        # akm-root asserts.
        let repo = (make-repo "akm")
        let root = (make-runtime "akm")
        let t = (make-tmux "akm" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                let got = (spawn-worker $t $repo --task "" --skill "doc-plan" --isolation "main" --session "sid-akm")
                assert-eq $got.window "impl-t1@dotfiles" ""
                assert-eq $got.cwd $repo "an AKM stage runs where AKM can be read and written"
                assert-eq $got.branch "main" "on the default branch, where AKM lives"
                assert-true (not (($repo | path join ".worktrees") | path exists)) "and allocates no task worktree"
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
        let marker = ([(fixture-base) $"piw-t4-env-(random chars --length 6)"] | path join)
        let t = (make-tmux "env" $"env | grep PI_WORKER_ > ($marker); sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                spawn-worker $t $repo --task "t1" --session "sid-env" --skill "wk-build"
                wait-until {|| ($marker | path exists) and ((open --raw $marker | str trim) | is-not-empty) } --timeout 5sec --interval 50ms --what $"($marker) to be written by the stub pi"
                let seen = (open --raw $marker)
                for pair in ["PI_WORKER_RUN=run-1" "PI_WORKER_UID=impl-a" "PI_WORKER_ROLE=impl" "PI_WORKER_SESSION=sid-env" "PI_WORKER_SKILL=wk-build" "PI_WORKER_WINDOW=impl-t1@dotfiles" "PI_WORKER_BRANCH=wk-t1.0" "PI_WORKER_TASK=t1"] {
                    assert-true ($seen | str contains $pair) $"the worker window carries ($pair)"
                }
            }
        }
        rm -f $marker; drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/a-worker-with-no-ticket-carries-no-PI_WORKER_TASK-at-all" {
        # dotfiles-v13r exports the ticket alongside the other PI_WORKER_*
        # vars, and an empty one is exported as NOTHING rather than as an empty
        # string: a reader cannot tell `PI_WORKER_TASK=` from "this stage has a
        # ticket whose id is the empty string", and absence is the signal the
        # rest of this protocol already uses for a field nobody set.
        let repo = (make-repo "env-no-task")
        let root = (make-runtime "env-no-task")
        let marker = ([(fixture-base) $"piw-t4-envnotask-(random chars --length 6)"] | path join)
        let t = (make-tmux "env-no-task" $"env | grep PI_WORKER_ > ($marker); sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                spawn-worker $t $repo --task "" --session "sid-env" --skill "wk-build"
                wait-until {|| ($marker | path exists) and ((open --raw $marker | str trim) | is-not-empty) } --timeout 5sec --interval 50ms --what $"($marker) to be written by the stub pi"
                let seen = (open --raw $marker)
                assert-true ($seen | str contains "PI_WORKER_UID=impl-a") "sanity: the window did carry the other identity vars"
                assert-true (not ($seen | str contains "PI_WORKER_TASK")) $"a ticketless worker must carry no PI_WORKER_TASK, got: ($seen)"
            }
        }
        rm -f $marker; drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    # ------------------------------------------------------------ visibility
    (run-case "spawn/a-worker-that-dies-at-startup-stays-visible" {
        # Pi exiting before it initialises must not erase the evidence. The
        # window stays so an operator can read why, and the identity is already
        # on the bus.
        #
        # The stub pauses before exiting, and that is deliberate rather than a
        # fudge. `remain-on-exit` cannot be set atomically with `new-window`:
        # tmux has no flag for it, and `-d` leaves the active window unchanged
        # so a following `set-option` with no target would hit the wrong one.
        # worker-spawn therefore sets it on the very next line and says so, and
        # a stub that exits in the same instant is racing a gap the product
        # cannot close. This case used to run `exit 3` with no pause and pass
        # by usually winning that race; under load it lost, which is how it
        # became one of four cases that took turns failing.
        #
        # What is worth pinning is the contract — a worker that dies during
        # startup leaves its window and its identity behind — not the width of
        # a gap tmux owns.
        let repo = (make-repo "crash")
        let root = (make-runtime "crash")
        let t = (make-tmux "crash" "sleep 0.4; echo 'pi failed to start' >&2; exit 3")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
                # Wait for the death, rather than for a duration. The old
                # `sleep 400ms` was simultaneously too long (the process was
                # already gone) and too short (on a loaded box it was not).
                wait-until {||
                    let dead = (do { ^tmux -L $t.socket list-panes -t $got.window -F "#{pane_dead}" } | complete)
                    $dead.exit_code == 0 and (($dead.stdout | lines | first | default "" | str trim) == "1")
                } --timeout 15sec --interval 50ms --what $"pane for ($got.window) to report dead"
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
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "wk-build" --socket $t.socket)
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
        # The server is reachable and the target resolves; new-window itself
        # refuses, so everything before it has already succeeded. A bad
        # --project no longer reaches this point — it is refused before any
        # allocation (dotfiles-k5vt) — so the failure is injected directly.
        stub-tmux-refusing-new-window "order" $t.bin (^which tmux | str trim)
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                assert-rejects {
                    worker-spawn --run "run-1" --uid "impl-a" --role "impl" --subject "t1" --project "dotfiles" --repo $repo --task "t1" --session "sid-o" --skill "wk-build" --isolation "worktree" --socket $t.socket
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
        let t = {socket: "piw-t4-does-not-exist", bin: ""}
        with-runtime $root {
            assert-rejects {
                spawn-worker $t $repo --task "t1" --session "sid-1" --skill "wk-build"
            } "tmux" "an unreachable tmux server is named in the failure"
        }
        rm -rf $root; rm -rf $repo
    })

    # -------------------------------------------- the retired registry
    (run-case "spawn/a-legacy-payload-bearing-stages-file-has-no-effect" {
        # sp029 T8: the registry retired. A stages.json installed under the
        # previous shape (isolation/payload per stage) is simply never read —
        # nothing here opens PI_WORKER_STAGES any more — so spawn behaves
        # identically whether or not one is sitting there. Ignored, not
        # half-honored.
        let repo = (make-repo "legacy-stages")
        let root = (make-runtime "legacy-stages")
        let t = (make-tmux "legacy-stages" "sleep 30")
        let legacy = ([(fixture-base) $"piw-legacy-stages-(random chars --length 6).json"] | path join)
        '{"stages":[{"name":"wk-build","isolation":"worktree","payload":"ticket"}]}' | save -f $legacy
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH), PI_WORKER_STAGES: $legacy} {
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree")
                assert-eq $got.window "impl-t1@dotfiles" "spawn succeeds exactly as it would with no registry file at all"
            }
        }
        rm -f $legacy; drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/an-unparseable-stages-file-has-no-effect-either" {
        # Nothing reads PI_WORKER_STAGES any more, so a file that would not
        # even parse as JSON costs spawn nothing.
        let repo = (make-repo "bad-stages")
        let root = (make-runtime "bad-stages")
        let t = (make-tmux "bad-stages" "sleep 30")
        let broken = ([(fixture-base) $"piw-broken-stages-(random chars --length 6).json"] | path join)
        "not json at all {{{" | save -f $broken
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH), PI_WORKER_STAGES: $broken} {
                let got = (spawn-worker $t $repo --task "t1" --session "sid-1" --skill "wk-build" --isolation "worktree")
                assert-eq $got.window "impl-t1@dotfiles" "spawn succeeds; a file it never opens cannot fail it"
            }
        }
        rm -f $broken; drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    # sp029 T8: "spawn/refuses-an-unknown-skill" and
    # "spawn/work-skill-requires-a-task-id" retired along with the stage
    # registry they exercised. `--skill` is now an informational label, not a
    # lookup key, so no name is "unknown", and whether `--task` is required
    # was the registry's `payload: ticket` gate — the transport does not gate
    # a message's shape any more (see `main spawn`'s own comment on --task).

    (run-case "spawn/refuses-a-uid-that-already-has-state-in-this-run" {
        # Reusing an address silently inherited the previous occupant's mail.
        # Observed live: a fresh spawn into run x1 / uid w1 got sequence 3 for
        # its first message, `wait` handed back a result envelope written half
        # an hour earlier by a different worker, and `stop` reported "already
        # stopped" from a stale marker. The agent reported that stale result as
        # its own. An occupied address must be refused, not quietly moved into.
        let repo = (make-repo "occupied")
        let root = (make-runtime "occupied")
        let t = (make-tmux "occupied" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                spawn-worker $t $repo --task "t1" --skill "wk-build" --session "sid-1"
                assert-rejects {
                    spawn-worker $t $repo --task "t1" --skill "wk-build" --session "sid-2"
                } "already" "the second spawn is refused"
                # And it names the address, so the fix is obvious.
                assert-rejects {
                    spawn-worker $t $repo --task "t1" --skill "wk-build" --session "sid-2"
                } "impl-a" "naming the uid"
                # And naming the VERB that resolves it. Observed live: an agent
                # restricted to the tool read "remove <path>", had no way to
                # remove a path, and gave up — the remedy has to be offered in
                # the vocabulary the caller actually has.
                assert-rejects {
                    spawn-worker $t $repo --task "t1" --skill "wk-build" --session "sid-2"
                } "rm --run" "pointing at the verb, not the filesystem"
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    (run-case "spawn/a-different-uid-in-the-same-run-is-fine" {
        # Runs hold many workers; only the address has to be free.
        let repo = (make-repo "sibling")
        let root = (make-runtime "sibling")
        let t = (make-tmux "sibling" "sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                spawn-worker $t $repo --task "t1" --skill "wk-build" --session "sid-1"
                let b = (worker-spawn --run "run-1" --uid "impl-b" --role "impl" --subject "t2" --project "dotfiles" --repo $repo --task "t2" --session "sid-2" --skill "wk-build" --isolation "worktree" --socket $t.socket)
                assert-eq $b.uid "impl-b" "a free address spawns normally"
            }
        }
        drop-tmux $t; rm -rf $root; rm -rf $repo
    })

    # -------------------------------------------- self-claimed sessions (T7)
    (run-case "self-claim/a-plain-window-carries-no-worker-env" {
        # sp029 T7: the extension decides "nobody spawned me" by PI_WORKER_UID
        # being unset, and claims its own address on that basis. That gate
        # only fires correctly if an ordinary window — one worker-spawn never
        # touched — really carries none of the PI_WORKER_* variables a spawned
        # worker's window gets (see spawn/passes-worker-identity-into-the-
        # window-environment above). A leak here would make the extension
        # think an operator's own session was a worker, or vice versa.
        let repo = (make-repo "self-claim-env")
        let root = (make-runtime "self-claim-env")
        let marker = ([(fixture-base) $"piw-t7-plain-env-(random chars --length 6)"] | path join)
        # The assertion below is on ABSENCE of content, so polling on the
        # marker itself is not possible (an empty grep match is the expected,
        # correct outcome, not something still in flight). A separate sentinel
        # written right after the redirect is what we can wait for instead —
        # its existence proves the env|grep step already ran to completion.
        let done = $"($marker).done"
        let t = (make-tmux "self-claim-env" $"env | grep '^PI_WORKER_' > ($marker); touch ($done); sleep 30")
        with-runtime $root {
            with-env {PATH: ([$t.bin] ++ $env.PATH)} {
                # A plain window, created directly rather than through
                # worker-spawn — the shape of an ordinary interactive session.
                # "pi" resolves through PATH to the stub in $t.bin, same as
                # worker-spawn's own new-window call does.
                ^tmux -L $t.socket new-window -t "dotfiles" -n "plain" "pi"
                wait-until {|| $done | path exists } --timeout 5sec --interval 50ms --what $"($done) to signal the stub finished writing ($marker)"
                let seen = (if ($marker | path exists) { open --raw $marker } else { "" })
                assert-true (($seen | str trim) | is-empty) "an ordinary window carries no PI_WORKER_* — the self-claim gate never fires on it otherwise"
            }
        }
        rm -f $marker; rm -f $done; drop-tmux $t; rm -rf $root; rm -rf $repo
    })

]

$cases | to json
