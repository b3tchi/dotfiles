#!/usr/bin/env nu
# Worker worktree cases (sp028 T3).
#
# Every case runs against a throwaway git repository and its own
# XDG_RUNTIME_DIR. `git worktree` has enough behavior of its own — locks,
# prunable registrations, a branch whose directory is gone — that a fake would
# only test the fake, so these drive real git.
#
# The bias throughout is toward refusing: allocation must never hand back a
# worktree that already holds someone's work, and cleanup must never delete
# work that was not committed and accepted. A false refusal costs a retry; a
# false deletion costs the work.

use harness.nu *
use ../../claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu *

def dirty-it [repo: string, path: string] {
    "uncommitted\n" | save -f ($path | path join "scratch.txt")
}

let cases = [
    # ------------------------------------------------------------ allocation
    (run-case "worktree/allocates-the-first-iteration" {
        let repo = (make-repo "alloc")
        let root = (make-runtime "alloc")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "dotfiles-963w.3")
            assert-eq $got.branch "wk-dotfiles-963w.3.0" "first attempt is iteration 0"
            assert-eq ($got.path | path basename) "wk-dotfiles-963w.3.0" "directory name matches the branch"
            assert-true ($got.path | path exists) "the worktree is on disk"
            assert-eq (git-in $repo "rev-parse" "--abbrev-ref" "HEAD" --) "main" "the main worktree is left on its own branch"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/second-request-takes-the-next-iteration" {
        let repo = (make-repo "alloc2")
        let root = (make-runtime "alloc2")
        with-runtime $root {
            let first = (worktree-allocate --repo $repo --task "t1")
            let second = (worktree-allocate --repo $repo --task "t1")
            assert-eq $first.iteration 0 ""
            assert-eq $second.iteration 1 "a rejected attempt's worktree is not silently reused"
            assert-true ($first.path != $second.path) ""
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/branch-without-a-directory-is-not-reused" {
        # A rejected iteration whose directory was swept still owns its branch.
        # Handing that branch to a new worker would put two attempts' history on
        # one ref, so allocation must step past it.
        let repo = (make-repo "orphan")
        let root = (make-runtime "orphan")
        with-runtime $root {
            let first = (worktree-allocate --repo $repo --task "t1")
            ^git -C $repo worktree remove --force $first.path
            assert-true (not ($first.path | path exists)) "directory is gone"
            assert-true ((git-in $repo "branch" "--list" "wk-t1.0") | is-not-empty) "but the branch remains"

            let next = (worktree-allocate --repo $repo --task "t1")
            assert-eq $next.branch "wk-t1.1" "allocation steps past the orphaned branch"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/never-returns-a-branch-that-already-existed" {
        # The property, stated independently of how it is achieved. The
        # branch-scan in worktree-allocate is only a fast path — the actual
        # guarantee is that `git worktree add -b` fails on an existing ref — so
        # this asserts the outcome rather than the mechanism, and keeps holding
        # if the fast path is ever removed.
        let repo = (make-repo "preexisting")
        let root = (make-runtime "preexisting")
        with-runtime $root {
            for n in 0..3 { ^git -C $repo branch $"wk-t1.($n)" }
            let before = (
                git-in $repo "branch" "--list" "--format" "%(refname:short)"
                | lines
                | each {|b| $b | str trim }
                | where {|b| $b | str starts-with "wk-t1." }
                | sort
            )

            let got = (worktree-allocate --repo $repo --task "t1")
            assert-true ($got.branch not-in $before) $"($got.branch) must not be one of the pre-existing refs"
            assert-eq $got.branch "wk-t1.4" "allocation lands past every existing iteration"
            # Nothing that already existed was moved or checked out.
            for b in $before {
                assert-eq (git-in $repo "rev-parse" $b) (git-in $repo "rev-parse" "main") $"($b) is untouched"
            }
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/never-moves-or-resets-an-existing-branch" {
        # The invariant underneath the previous case: a rejected iteration's
        # COMMITS must survive allocation. Two independent mechanisms protect
        # it — the branch scan skips past existing refs, and `worktree add -b`
        # refuses an existing one — and this asserts the outcome, so losing
        # either (or both) is caught here rather than in production.
        let repo = (make-repo "no-reset")
        let root = (make-runtime "no-reset")
        with-runtime $root {
            let first = (worktree-allocate --repo $repo --task "t1")
            "rejected attempt\n" | save -f ($first.path | path join "attempt.txt")
            ^git -C $first.path add -A
            ^git -C $first.path commit -q -m "rejected work"
            let kept = (git-in $repo "rev-parse" "wk-t1.0")
            ^git -C $repo worktree remove --force $first.path

            let next = (worktree-allocate --repo $repo --task "t1")
            assert-true ($next.branch != "wk-t1.0") "the occupied ref is not handed out again"
            assert-eq (git-in $repo "rev-parse" "wk-t1.0") $kept "and its commit is exactly where it was"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/parallel-allocation-never-collides" {
        # Two workers asking at once is the interesting case: both must get a
        # usable worktree, and they must not be the same one.
        let repo = (make-repo "race")
        let root = (make-runtime "race")
        with-runtime $root {
            let script = ([$root "allocate.nu"] | path join)
            $"use (worker-script $env.FILE_PWD) *\nworktree-allocate --repo \"($repo)\" --task \"t1\" | get branch | print" | save -f $script

            let outs = ([1 2 3 4] | par-each {|n|
                with-env {XDG_RUNTIME_DIR: $root} { ^$nu.current-exe $script | complete }
            })
            for o in $outs { assert-eq $o.exit_code 0 $"allocation failed: ($o.stderr)" }

            let branches = ($outs | each {|o| $o.stdout | str trim } | sort)
            assert-eq ($branches | uniq | length) 4 $"four requests must yield four distinct branches, got ($branches | str join ', ')"
            for b in $branches {
                assert-true ((git-in $repo "branch" "--list" $b) | is-not-empty) $"($b) really exists"
            }
        }
        rm -rf $root; rm -rf $repo
    })

    # -------------------------------------------------------- identity record
    (run-case "worktree/allocation-records-cwd-in-the-identity-envelope" {
        let repo = (make-repo "identity")
        let root = (make-runtime "identity")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            bus-identity "impl-a" --run "run-1" --identity {
                role: "impl"
                cwd: $got.path
                branch: $got.branch
                session: "sid-1"
                skill: "wk-build"
                window: "impl-a@dotfiles"
            }
            let recorded = (bus-identity-of "impl-a" --run "run-1")
            assert-eq $recorded.cwd $got.path "the identity envelope carries the allocated worktree"
            assert-eq $recorded.branch $got.branch ""
            assert-eq $recorded.session "sid-1" ""
        }
        rm -rf $root; rm -rf $repo
    })

    # -------------------------------------------------------------- validation
    (run-case "worktree/validate-accepts-a-clean-matching-worktree" {
        let repo = (make-repo "valid")
        let root = (make-runtime "valid")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            worktree-validate --repo $repo --path $got.path --branch $got.branch
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/validate-rejects-a-dirty-worktree" {
        let repo = (make-repo "dirty")
        let root = (make-runtime "dirty")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            dirty-it $repo $got.path
            assert-rejects {
                worktree-validate --repo $repo --path $got.path --branch $got.branch
            } "uncommitted" "a worktree holding uncommitted work is not reusable"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/validate-rejects-a-branch-mismatch" {
        let repo = (make-repo "mismatch")
        let root = (make-runtime "mismatch")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            assert-rejects {
                worktree-validate --repo $repo --path $got.path --branch "wk-someone-else.0"
            } "branch" "a worktree checked out on another branch is not this worker's"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/validate-rejects-an-unregistered-path" {
        let repo = (make-repo "unregistered")
        let root = (make-runtime "unregistered")
        with-runtime $root {
            let stray = ($repo | path join "not-a-worktree")
            mkdir $stray
            assert-rejects {
                worktree-validate --repo $repo --path $stray --branch "wk-t1.0"
            } "registered" "a directory git does not know about is not a worktree"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/validate-rejects-a-locked-worktree" {
        let repo = (make-repo "locked")
        let root = (make-runtime "locked")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            ^git -C $repo worktree lock $got.path
            assert-rejects {
                worktree-validate --repo $repo --path $got.path --branch $got.branch
            } "locked" "a locked worktree is deliberately held by someone"
            ^git -C $repo worktree unlock $got.path
        }
        rm -rf $root; rm -rf $repo
    })

    # ----------------------------------------------------------------- cleanup
    (run-case "worktree/cleanup-refuses-without-acceptance-evidence" {
        # The default answer is no. A worker window stays inspectable until
        # something explicitly says the work is done with.
        let repo = (make-repo "no-evidence")
        let root = (make-runtime "no-evidence")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            assert-rejects {
                worktree-cleanup --repo $repo --path $got.path --branch $got.branch
            } "evidence" "cleanup without acceptance or merge evidence is refused"
            assert-true ($got.path | path exists) "and the worktree is still there"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/cleanup-refuses-uncommitted-work-even-when-accepted" {
        # Acceptance is about the reported result, not about whatever is sitting
        # unstaged in the directory. Deleting that is unrecoverable.
        let repo = (make-repo "dirty-accept")
        let root = (make-runtime "dirty-accept")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            dirty-it $repo $got.path
            assert-rejects {
                worktree-cleanup --repo $repo --path $got.path --branch $got.branch --accepted
            } "uncommitted" "accepted work does not license deleting uncommitted changes"
            assert-true ($got.path | path exists) ""
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/cleanup-refuses-untracked-files" {
        let repo = (make-repo "untracked")
        let root = (make-runtime "untracked")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            "notes\n" | save -f ($got.path | path join "scratch-notes.txt")
            assert-rejects {
                worktree-cleanup --repo $repo --path $got.path --branch $got.branch --accepted
            } "uncommitted" "an untracked file is unrecoverable once deleted"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/cleanup-proceeds-on-explicit-acceptance" {
        let repo = (make-repo "accept")
        let root = (make-runtime "accept")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            worktree-cleanup --repo $repo --path $got.path --branch $got.branch --accepted
            assert-true (not ($got.path | path exists)) "the worktree is removed"
            assert-true ((git-in $repo "branch" "--list" $got.branch) | is-empty) "and its branch with it"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/cleanup-proceeds-on-verified-merge-evidence" {
        # Merge evidence is checked against git, not taken on the caller's word:
        # the branch must actually be an ancestor of the base it claims to have
        # landed in.
        let repo = (make-repo "merged")
        let root = (make-runtime "merged")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            "work\n" | save -f ($got.path | path join "work.txt")
            ^git -C $got.path add -A
            ^git -C $got.path commit -q -m "work"
            ^git -C $repo merge --no-ff -q -m "merge" $got.branch

            worktree-cleanup --repo $repo --path $got.path --branch $got.branch --merged-into "main"
            assert-true (not ($got.path | path exists)) "a landed worktree is cleaned up"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/cleanup-refuses-unverified-merge-claim" {
        let repo = (make-repo "unmerged")
        let root = (make-runtime "unmerged")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            "work\n" | save -f ($got.path | path join "work.txt")
            ^git -C $got.path add -A
            ^git -C $got.path commit -q -m "work"
            # Never merged — the claim is false.
            assert-rejects {
                worktree-cleanup --repo $repo --path $got.path --branch $got.branch --merged-into "main"
            } "not merged" "a merge claim is verified against git, not believed"
            assert-true ($got.path | path exists) "the unmerged work survives"
        }
        rm -rf $root; rm -rf $repo
    })

    # ------------------------------------------------- metadata outlives the tree
    (run-case "worktree/session-and-completion-survive-worktree-removal" {
        # Bus state lives in the runtime directory, never inside the worktree,
        # so the resume command and the result outlive the cleanup. Losing them
        # would make an accepted worker unresumable.
        let repo = (make-repo "survive")
        let root = (make-runtime "survive")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            bus-identity "impl-a" --run "run-1" --identity {
                role: "impl", cwd: $got.path, branch: $got.branch
                session: "sid-9", skill: "wk-build", window: "impl-a@dotfiles"
            }
            bus-result "impl-a" --run "run-1" --result {
                status: "complete", summary: "done", validation: "PASS"
                window: "impl-a@dotfiles", session: "sid-9", resume: "pi --session sid-9"
            }

            worktree-cleanup --repo $repo --path $got.path --branch $got.branch --accepted
            assert-true (not ($got.path | path exists)) "worktree gone"

            let identity = (bus-identity-of "impl-a" --run "run-1")
            assert-eq $identity.session "sid-9" "the session id survives"
            let result = (bus-wait --run "run-1")
            assert-eq $result.payload.resume "pi --session sid-9" "the exact resume command survives"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "worktree/partial-cleanup-leaves-metadata-intact" {
        # Failure injection: the directory removal succeeds and the branch
        # deletion fails. The worker's evidence must still be readable, because
        # that is what the operator needs in order to finish the job by hand.
        let repo = (make-repo "partial")
        let root = (make-runtime "partial")
        with-runtime $root {
            let got = (worktree-allocate --repo $repo --task "t1")
            bus-identity "impl-a" --run "run-1" --identity {
                role: "impl", cwd: $got.path, branch: $got.branch
                session: "sid-p", skill: "wk-build", window: "impl-a@dotfiles"
            }
            # An unmerged commit makes `git branch -d` refuse, so removal of the
            # directory succeeds while branch deletion fails.
            "work\n" | save -f ($got.path | path join "work.txt")
            ^git -C $got.path add -A
            ^git -C $got.path commit -q -m "work"

            let outcome = (try {
                worktree-cleanup --repo $repo --path $got.path --branch $got.branch --accepted
                "no error"
            } catch {|e| $e.msg })

            assert-true ($outcome != "no error") "an unmergeable branch surfaces the failure"
            assert-eq (bus-identity-of "impl-a" --run "run-1" | get session) "sid-p" "metadata survives a partial cleanup"
        }
        rm -rf $root; rm -rf $repo
    })
    # ------------------------------------------- AKM stages and the main tree
    #
    # dotfiles-ptba: every worker used to get an isolated `bd-<subject>.<N>`
    # worktree, AKM stages included. But `akm-root` refuses to serve any
    # worktree but the main one — deliberately, because "AKM artifacts describe
    # shared product knowledge and live on the default branch... feature
    # worktrees exist only for code work". So an AKM worker could not do its
    # job where it was put, and the guard's own advice ("cd <main> and retry")
    # told it to leave. Observed live: it did, and the isolation the worktree
    # existed to provide evaporated silently.
    #
    # The fix follows what akm-root already asserts rather than fighting it.

    (run-case "worktree/an-akm-stage-is-placed-in-the-main-worktree" {
        let repo = (make-repo "akm-place")
        let placed = (worker-placement --repo $repo --skill "doc-plan" --subject "sp028")

        assert-eq $placed.path $repo "an AKM stage runs where AKM can be read and written"
        assert-true (not ($placed.branch | str starts-with "wk-")) $"no task branch for an AKM stage, got ($placed.branch)"
        assert-eq $placed.branch "main" "it works on the default branch, which is where AKM lives"
        assert-true (not (($repo | path join ".worktrees") | path exists)) "and allocates nothing"
        rm -rf $repo
    })

    (run-case "worktree/a-work-stage-still-gets-its-own-isolated-worktree" {
        # The regression guard for the above: code work must stay isolated.
        let repo = (make-repo "work-place")
        let placed = (worker-placement --repo $repo --skill "wk-build" --subject "dotfiles-963w.4")

        assert-eq $placed.branch "wk-dotfiles-963w.4.0" "a work stage gets its task branch"
        assert-true ($placed.path != $repo) "in a directory of its own"
        assert-true ($placed.path | path exists) "which exists on disk"
        rm -rf $repo
    })

    (run-case "worktree/cleanup-refuses-to-remove-the-main-worktree" {
        # Defense in depth. An AKM worker's cwd IS the main worktree, and
        # `worker-accept` cleans up `identity.cwd`. git would refuse the removal
        # on its own, but it would refuse confusingly, at the end of a sequence
        # that has already killed the window.
        let repo = (make-repo "no-main-rm")
        assert-rejects {
            worktree-cleanup --repo $repo --path $repo --branch "main" --accepted
        } "main worktree" "cleanup must never target the main worktree"
        assert-true ($repo | path exists) "and it survives"
        rm -rf $repo
    })


    (run-case "worktree/a-tilde-prefixed-repo-is-expanded-not-passed-through" {
        # An agent driving the tool writes `~/.dotfiles` because that is how a
        # human writes it. Nothing expands a tilde on the way to git, so it
        # arrived literally and git failed with "cannot change to '~/.dotfiles'"
        # — a confusing error for a correct-looking argument.
        # The repo must live under $HOME for a tilde to mean anything, so this
        # case makes its own there rather than in the temp dir.
        let home = ($env.HOME | path expand)
        let repo = ($home | path join $"pi-worker-tilde-(random chars --length 6)")
        rm -rf $repo; mkdir $repo
        ^git -C $repo init -q -b main
        ^git -C $repo config user.email "test@example.com"
        ^git -C $repo config user.name "Test"
        "seed\n" | save -f ($repo | path join "README.md")
        ^git -C $repo add -A
        ^git -C $repo commit -q -m seed

        let tilded = ($repo | str replace $home "~")
        assert-true ($tilded | str starts-with "~") $"fixture must be tilde-prefixed, got ($tilded)"
        assert-eq (main-worktree $tilded) $repo "a ~ path resolves to the same worktree"
        assert-eq (main-worktree $repo) $repo "an absolute path still works"
        rm -rf $repo
    })


    # ------------------------------------------------------- project sweep
    #
    # `stop` leaves a worker's worktree and branch behind on purpose: they may
    # hold unmerged commits, and the tree is the only place to look at what a
    # stopped worker did. That is right per WORKER and wrong per PROJECT — a
    # smoke-test round left 29 trees and 953 MB in this very repo before
    # anything swept them. `worktrees-reclaim` is the project-scoped sweep, and
    # what survives it is the session id on the bus, which is all a resume
    # needs.

    (run-case "reclaim/sweeps-a-worktree-no-live-worker-owns" {
        let repo = (make-repo "gc-orphan")
        let root = (make-runtime "gc-orphan")
        with-runtime $root {
            let one = (worktree-allocate --repo $repo --task "t1")
            let got = (worktrees-reclaim --repo $repo)
            assert-eq ($got.removed | length) 1 "the orphan tree is reclaimed"
            assert-true (not ($one.path | path exists)) "and it is gone from disk"
            assert-eq $got.branches_deleted [$one.branch] "its branch goes with it"
            assert-true ((git-in $repo "branch" "--list" $one.branch) | is-empty) "really gone"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "reclaim/never-sweeps-a-worktree-a-live-worker-is-in" {
        # The refusal that matters: a sweep that takes the tree out from under
        # a working agent destroys work in progress, and --force is no licence
        # for it either.
        let repo = (make-repo "gc-live")
        let root = (make-runtime "gc-live")
        with-runtime $root {
            let mine = (worktree-allocate --repo $repo --task "live")
            bus-identity "impl-1" --run "r1" --identity {
                role: "impl", cwd: $mine.path, branch: $mine.branch
                session: "sid-1", skill: "wk-build", window: "impl-live@dotfiles"
            }
            let got = (worktrees-reclaim --repo $repo --force)
            assert-eq ($got.removed | length) 0 "nothing reclaimed"
            assert-true ($mine.path | path exists) "the live worker keeps its tree"
            assert-eq ($got.kept | first | get reason) "r1/impl-1 is created" "and the report names who has it"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "reclaim/sweeps-a-reported-workers-tree" {
        # Where the leftovers actually came from: 26 of the 29 trees in this
        # repo belonged to workers at `complete` — reported, never accepted,
        # holding a directory forever. A worker that has reported is done with
        # its files; what it waits for is a decision, and a decision does not
        # need a directory. Its session id — on the bus, not in the tree — is
        # what a restore uses.
        let repo = (make-repo "gc-terminal")
        let root = (make-runtime "gc-terminal")
        with-runtime $root {
            let done = (worktree-allocate --repo $repo --task "done")
            bus-identity "impl-1" --run "r1" --identity {
                role: "impl", cwd: $done.path, branch: $done.branch
                session: "sid-1", skill: "wk-build", window: "impl-done@dotfiles"
            }
            bus-result "impl-1" --run "r1" --result {
                status: "complete", summary: "did the thing"
                window: "impl-done@dotfiles", session: "sid-1", resume: "pi --session sid-1"
            }
            assert-eq (bus-status "impl-1" --run "r1" | get state) "complete" "reported, not accepted"
            let got = (worktrees-reclaim --repo $repo)
            assert-eq ($got.removed | length) 1 "a reported worker's tree is reclaimed"
            assert-true (not ($done.path | path exists)) ""
            # The bus keeps what a restore needs, and only that.
            assert-eq (bus-identity-of "impl-1" --run "r1" | get session) "sid-1" "the session id survives the sweep"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "reclaim/every-in-flight-state-protects-its-tree" {
        # created, running, waiting_human, blocked: four ways of having work in
        # flight, and the sweep must recognise all of them. A tree taken out
        # from under a working agent destroys work nothing can recover.
        let repo = (make-repo "gc-inflight")
        let root = (make-runtime "gc-inflight")
        with-runtime $root {
            # `running` is derived from a `reopened` marker that only
            # worker-resume writes (and resume needs tmux), so it is asserted
            # by the transition suite rather than re-staged here; the three
            # below are the ones a bus fixture can reach.
            for state in ["created" "waiting_human" "blocked"] {
                let tree = (worktree-allocate --repo $repo --task $state)
                bus-identity $"impl-($state)" --run "r1" --identity {
                    role: "impl", cwd: $tree.path, branch: $tree.branch
                    session: $"sid-($state)", skill: "wk-build", window: $"impl-($state)@dotfiles"
                }
                if $state != "created" {
                    bus-result $"impl-($state)" --run "r1" --result {
                        status: $state, summary: $"it is ($state)"
                        window: $"impl-($state)@dotfiles", session: $"sid-($state)", resume: "pi --session x"
                    }
                }
                assert-eq (bus-status $"impl-($state)" --run "r1" | get state) $state ""
            }
            let got = (worktrees-reclaim --repo $repo --force)
            assert-eq ($got.removed | length) 0 $"no in-flight tree may be swept, got ($got.removed)"
            assert-eq ($got.kept | length) 3 "and each is reported with its owner"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "reclaim/keeps-a-dirty-tree-and-says-why" {
        let repo = (make-repo "gc-dirty")
        let root = (make-runtime "gc-dirty")
        with-runtime $root {
            let one = (worktree-allocate --repo $repo --task "t1")
            dirty-it $repo $one.path
            let got = (worktrees-reclaim --repo $repo)
            assert-eq ($got.removed | length) 0 "uncommitted work is not swept"
            assert-true ($one.path | path exists) ""
            assert-true (($got.kept | first | get reason) | str contains "uncommitted") "and the report says why"

            # --force is the operator saying they know. It exists because the
            # alternative is a person running `rm -rf` by hand, which takes the
            # live trees with it.
            let forced = (worktrees-reclaim --repo $repo --force)
            assert-eq ($forced.removed | length) 1 "--force takes it"
            assert-true (not ($one.path | path exists)) ""
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "reclaim/keeps-a-branch-that-carries-unmerged-commits" {
        # The tree is re-creatable from the branch; the commits are not
        # re-creatable from anything. So the directory goes and the ref stays,
        # and the report names it rather than leaving it to be discovered.
        let repo = (make-repo "gc-unmerged")
        let root = (make-runtime "gc-unmerged")
        with-runtime $root {
            let one = (worktree-allocate --repo $repo --task "t1")
            "work\n" | save -f ($one.path | path join "work.txt")
            ^git -C $one.path add -A
            ^git -C $one.path commit -q -m "work nobody merged"
            let got = (worktrees-reclaim --repo $repo)
            assert-eq ($got.removed | length) 1 "the directory is reclaimed"
            assert-true (not ($one.path | path exists)) ""
            assert-eq $got.branches_deleted [] "but the branch is not"
            assert-true ((git-in $repo "branch" "--list" $one.branch) | is-not-empty) "the commits survive on the ref"
            assert-true (($got.branches_kept | first | get reason) | str contains "not merged") "and the report says so"

            # Named so the operator can act: with --force the ref goes too.
            let forced = (worktrees-reclaim --repo $repo --force)
            assert-eq $forced.branches_deleted [$one.branch] "--force takes the ref"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "reclaim/deletes-a-merged-branch-whose-directory-is-already-gone" {
        # The other half of the leftover: a swept directory whose branch stayed
        # behind. Allocation steps past those refs, so they accumulate silently
        # and nothing ever names them.
        let repo = (make-repo "gc-bare-ref")
        let root = (make-runtime "gc-bare-ref")
        with-runtime $root {
            let one = (worktree-allocate --repo $repo --task "t1")
            ^git -C $repo worktree remove --force $one.path
            let got = (worktrees-reclaim --repo $repo)
            assert-eq ($got.removed | length) 0 "there is no directory to remove"
            assert-eq $got.branches_deleted [$one.branch] "the bare ref is what is left to reclaim"
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "reclaim/leaves-the-main-worktree-and-anything-not-a-workers-alone" {
        # The main worktree is the operator's, and a worktree outside
        # .worktrees/ was made by a person for their own reasons. Neither is a
        # sweep's business, and `wk-` is the only naming this owns.
        let repo = (make-repo "gc-scope")
        let root = (make-runtime "gc-scope")
        with-runtime $root {
            let outside = ($repo | path dirname | path join $"outside-(random chars --length 6)")
            ^git -C $repo worktree add --quiet -b mine $outside
            let got = (worktrees-reclaim --repo $repo)
            assert-eq ($got.removed | length) 0 "nothing to sweep"
            assert-true ($repo | path exists) "the main worktree survives"
            assert-true ($outside | path exists) "and so does a hand-made one"
            assert-eq $got.branches_deleted [] "a branch that is not wk- is not touched"
            ^git -C $repo worktree remove --force $outside
        }
        rm -rf $root; rm -rf $repo
    })

    (run-case "reclaim/dry-run-reports-without-touching-anything" {
        # A sweep is irreversible and this one is project-wide, so there is a
        # way to read the plan before it runs.
        let repo = (make-repo "gc-dry")
        let root = (make-runtime "gc-dry")
        with-runtime $root {
            let one = (worktree-allocate --repo $repo --task "t1")
            let got = (worktrees-reclaim --repo $repo --dry-run)
            assert-eq ($got.removed | length) 1 "it reports what it would take"
            assert-true ($one.path | path exists) "and takes nothing"
            assert-true ((git-in $repo "branch" "--list" $one.branch) | is-not-empty) ""
        }
        rm -rf $root; rm -rf $repo
    })

]

$cases | to json
