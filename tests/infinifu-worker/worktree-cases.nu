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
use ../../claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu *

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
            assert-eq $got.branch "bd-dotfiles-963w.3.0" "first attempt is iteration 0"
            assert-eq ($got.path | path basename) "bd-dotfiles-963w.3.0" "directory name matches the branch"
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
            assert-true ((git-in $repo "branch" "--list" "bd-t1.0") | is-not-empty) "but the branch remains"

            let next = (worktree-allocate --repo $repo --task "t1")
            assert-eq $next.branch "bd-t1.1" "allocation steps past the orphaned branch"
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
            for n in 0..3 { ^git -C $repo branch $"bd-t1.($n)" }
            let before = (
                git-in $repo "branch" "--list" "--format" "%(refname:short)"
                | lines
                | each {|b| $b | str trim }
                | where {|b| $b | str starts-with "bd-t1." }
                | sort
            )

            let got = (worktree-allocate --repo $repo --task "t1")
            assert-true ($got.branch not-in $before) $"($got.branch) must not be one of the pre-existing refs"
            assert-eq $got.branch "bd-t1.4" "allocation lands past every existing iteration"
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
            let kept = (git-in $repo "rev-parse" "bd-t1.0")
            ^git -C $repo worktree remove --force $first.path

            let next = (worktree-allocate --repo $repo --task "t1")
            assert-true ($next.branch != "bd-t1.0") "the occupied ref is not handed out again"
            assert-eq (git-in $repo "rev-parse" "bd-t1.0") $kept "and its commit is exactly where it was"
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
                skill: "work-do"
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
                worktree-validate --repo $repo --path $got.path --branch "bd-someone-else.0"
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
                worktree-validate --repo $repo --path $stray --branch "bd-t1.0"
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
                session: "sid-9", skill: "work-do", window: "impl-a@dotfiles"
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
                session: "sid-p", skill: "work-do", window: "impl-a@dotfiles"
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
]

$cases | to json
