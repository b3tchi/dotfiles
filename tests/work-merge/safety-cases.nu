#!/usr/bin/env nu
# Shared-tree safety cases for land-bd-task.sh (auctions-zyvfr).
#
# The script lands into the MAIN worktree, which parallel sessions share. On
# 2026-09-25 a post-merge gate failed on a quoting bug in an inline `nu -c`,
# and the rollback — `git reset --hard ORIG_HEAD` — wiped another session's
# uncommitted edits in that tree. It happened three times that day, each on a
# FALSE gate failure. These cases pin the contract that replaced it:
#
#   - dirty paths the merge would touch → refuse BEFORE merging (exit 3);
#   - dirty paths the merge does not touch → tolerated, and they survive both
#     a successful land and a rollback;
#   - rollback never uses `reset --hard`: a conflicting merge is aborted, a
#     completed merge is undone with `reset --merge`, and a merge that another
#     session has already committed on top of is reverted, not reset away;
#   - the gate can be a script FILE, so no inline quoting is needed at all.

use harness.nu *

def head-sha [root: string]: nothing -> string {
    git -C $root rev-parse HEAD | str trim
}

def read-file [root: string, rel: string]: nothing -> string {
    open --raw ($root | path join $rel)
}

def merge-in-progress [root: string]: nothing -> bool {
    (do { git -C $root rev-parse -q --verify MERGE_HEAD } | complete).exit_code == 0
}

# Main gets a tracked file the task branch will NOT touch, so dirtying it is
# the "another session's WIP" shape from the incident.
def make-shared-repo [tag: string]: nothing -> string {
    let root = (make-repo $tag)
    "other session base\n" | save -f ($root | path join "other.yaml")
    "shared base\n" | save -f ($root | path join "shared.txt")
    git -C $root add other.yaml shared.txt
    git -C $root commit -q -m "base files"
    $root
}

let cases = [
    # ── The incident: unrelated WIP must survive a failing gate ─────────────
    (run-case "rollback/unrelated-dirty-survives-failing-gate" {
        let root = (make-shared-repo "wipsurvive")
        let bin = (make-stubs $root "closed")
        make-branch $root "60" "0" [{path: "src/task.txt", content: "task work\n"}]
        let pre = (head-sha $root)

        # Another session's uncommitted state: tracked edits and an untracked
        # file — all outside the merge's paths. (Staged WIP is its own case:
        # git refuses any non-ff merge over a dirty index.)
        "other session WIP\n" | save -f ($root | path join "other.yaml")
        "readme WIP\n" | save -f ($root | path join "README.md")
        "brand new notes\n" | save -f ($root | path join "notes.md")

        let out = (run-land $root $bin "60" "0" "false")

        assert-eq $out.exit_code 2 "a failing gate must reject:"
        assert-eq (head-sha $root) $pre "HEAD must be back at the pre-merge commit:"
        assert-true (not (merge-in-progress $root)) "no merge may be left in progress"
        assert-true (not ($root | path join "src/task.txt" | path exists)) "the merged file must be rolled back"
        # The load-bearing assertions — before the fix all three were wiped.
        assert-eq (read-file $root "other.yaml") "other session WIP\n" "unstaged WIP was destroyed:"
        assert-eq (read-file $root "README.md") "readme WIP\n" "second unstaged WIP was destroyed:"
        assert-eq (read-file $root "notes.md") "brand new notes\n" "untracked WIP was destroyed:"
        assert-str-contains (read-log $root "bd-calls.log" | str join "\n") "POST-MERGE FAIL" "rollback note missing:"
    })

    (run-case "land/unrelated-dirty-survives-successful-land" {
        let root = (make-shared-repo "wipok")
        let bin = (make-stubs $root "closed")
        make-branch $root "61" "0" [{path: "src/task.txt", content: "task work\n"}]
        "other session WIP\n" | save -f ($root | path join "other.yaml")

        let out = (run-land $root $bin "61" "0" "true")

        assert-eq $out.exit_code 0 $"unrelated dirt must not block a land: ($out.stderr)"
        assert-eq (read-file $root "src/task.txt") "task work\n" "the merge did not land:"
        assert-eq (read-file $root "other.yaml") "other session WIP\n" "unrelated WIP was lost:"
    })

    # ── Preflight: overlapping dirt is refused before any merge ─────────────
    (run-case "preflight/overlapping-tracked-edit-refuses" {
        let root = (make-shared-repo "overlap")
        let bin = (make-stubs $root "closed")
        make-branch $root "62" "0" [{path: "shared.txt", content: "task version\n"}]
        let pre = (head-sha $root)
        "someone's uncommitted edit\n" | save -f ($root | path join "shared.txt")

        let out = (run-land $root $bin "62" "0" "true")

        assert-eq $out.exit_code 3 "overlapping dirt must refuse with exit 3:"
        assert-str-contains $out.stderr "shared.txt" "the refusal must name the overlapping path:"
        assert-eq (head-sha $root) $pre "a refusal must not merge anything:"
        assert-eq (read-file $root "shared.txt") "someone's uncommitted edit\n" "the refusal destroyed the edit:"
        # A refusal is not a rejection — the task must not be reopened.
        assert-eq (read-log $root "bd-calls.log" | length) 0 "a refusal must not touch bd:"
        assert-true (git -C $root show-ref --quiet refs/heads/bd-62.0 | complete | get exit_code | $in == 0) "branch must survive"
    })

    (run-case "preflight/overlapping-untracked-file-refuses" {
        let root = (make-shared-repo "untracked")
        let bin = (make-stubs $root "closed")
        make-branch $root "63" "0" [{path: "docs/new.md", content: "from task\n"}]
        mkdir ($root | path join "docs")
        "local untracked\n" | save -f ($root | path join "docs/new.md")

        let out = (run-land $root $bin "63" "0" "true")

        assert-eq $out.exit_code 3 "an untracked file at a merge path must refuse:"
        assert-str-contains $out.stderr "docs/new.md" "the refusal must name the path:"
        assert-eq (read-file $root "docs/new.md") "local untracked\n" "the untracked file was clobbered:"
    })

    (run-case "preflight/overlapping-staged-edit-refuses" {
        let root = (make-shared-repo "staged")
        let bin = (make-stubs $root "closed")
        make-branch $root "64" "0" [{path: "shared.txt", content: "task version\n"}]
        "staged edit\n" | save -f ($root | path join "shared.txt")
        git -C $root add shared.txt

        let out = (run-land $root $bin "64" "0" "true")

        assert-eq $out.exit_code 3 "a staged overlapping edit must refuse:"
        assert-eq (read-file $root "shared.txt") "staged edit\n" "the staged edit was lost:"
    })

    (run-case "preflight/staged-unrelated-edit-refuses-cleanly" {
        let root = (make-shared-repo "stagedunrel")
        let bin = (make-stubs $root "closed")
        make-branch $root "70" "0" [{path: "src/task.txt", content: "task work\n"}]
        let pre = (head-sha $root)
        "staged WIP\n" | save -f ($root | path join "other.yaml")
        git -C $root add other.yaml

        let out = (run-land $root $bin "70" "0" "true")

        # git itself refuses a merge over a dirty index; before the fix that
        # surfaced as git's exit 2 — indistinguishable from a REJECTED gate.
        assert-eq $out.exit_code 3 "a staged index must refuse with exit 3, not masquerade as exit 2:"
        assert-str-contains $out.stderr "other.yaml" "the refusal must name the staged path:"
        assert-eq (head-sha $root) $pre "a refusal must not merge anything:"
        assert-eq (git -C $root diff --cached --name-only | str trim) "other.yaml" "the staging was disturbed:"
        assert-eq (read-log $root "bd-calls.log" | length) 0 "a refusal must not touch bd:"
    })

    # ── Rollback variants ───────────────────────────────────────────────────
    (run-case "merge/conflict-is-aborted-not-left-half-merged" {
        let root = (make-shared-repo "conflict")
        let bin = (make-stubs $root "closed")
        make-branch $root "65" "0" [{path: "shared.txt", content: "task side\n"}]
        "base side\n" | save -f ($root | path join "shared.txt")
        git -C $root commit -q -am "base moved"
        let pre = (head-sha $root)
        "other session WIP\n" | save -f ($root | path join "other.yaml")

        let out = (run-land $root $bin "65" "0" "true")

        assert-eq $out.exit_code 1 "a conflicting merge must fail:"
        assert-true (not (merge-in-progress $root)) "the conflicted merge must be aborted"
        assert-eq (head-sha $root) $pre "HEAD must not move:"
        assert-eq (read-file $root "shared.txt") "base side\n" "conflict markers left behind:"
        assert-eq (read-file $root "other.yaml") "other session WIP\n" "unrelated WIP lost on abort:"
    })

    (run-case "rollback/concurrent-commit-on-base-is-reverted-not-reset" {
        let root = (make-shared-repo "concurrent")
        let bin = (make-stubs $root "closed")
        make-branch $root "66" "0" [{path: "src/task.txt", content: "task work\n"}]

        # The gate stands in for a parallel session committing to base while
        # the gate runs, then failing. A reset to the pre-merge sha would
        # silently drop that session's commit.
        let gate = "echo concurrent > concurrent.txt && git add concurrent.txt && git -c user.email=t@e.invalid -c user.name=t commit -q -m concurrent && false"
        let out = (run-land $root $bin "66" "0" $gate)

        assert-eq $out.exit_code 2 "a failing gate must reject:"
        assert-eq (read-file $root "concurrent.txt") "concurrent\n" "the concurrent commit was destroyed:"
        let subjects = (git -C $root log --format=%s -3 | lines)
        assert-str-contains ($subjects | str join "|") "concurrent" "the concurrent commit left history:"
        assert-str-contains ($subjects | first) "Revert" "the merge should be reverted:"
        assert-true (not ($root | path join "src/task.txt" | path exists)) "the merge content must be undone"
    })

    (run-case "rollback/unsafe-undo-stops-at-exit-4-instead-of-hard-reset" {
        let root = (make-shared-repo "unsafe")
        let bin = (make-stubs $root "closed")
        make-branch $root "71" "0" [{path: "src/task.txt", content: "task work\n"}]

        # Someone edits a file the merge just brought in while the gate runs.
        # `reset --merge` cannot undo the merge without overwriting that edit,
        # so it refuses — and the script must stop there, not reach for --hard.
        let out = (run-land $root $bin "71" "0" "echo 'live edit' > src/task.txt; false")
        let calls = (read-log $root "bd-calls.log" | str join "\n")

        assert-eq $out.exit_code 4 "an unsafe rollback must stop with exit 4:"
        assert-eq (read-file $root "src/task.txt") "live edit\n" "the live edit was destroyed:"
        assert-str-contains $out.stderr "ROLLBACK INCOMPLETE" "the stop must be loud:"
        assert-str-contains $calls "ROLLBACK INCOMPLETE" "the bd note must say base still carries the merge:"
    })

    (run-case "preflight/path-with-spaces-is-named-intact" {
        let root = (make-shared-repo "spaces")
        let bin = (make-stubs $root "closed")
        make-branch $root "72" "0" [{path: "my notes.md", content: "task\n"}]
        "local\n" | save -f ($root | path join "my notes.md")

        let out = (run-land $root $bin "72" "0" "true")

        assert-eq $out.exit_code 3 "must refuse:"
        assert-str-contains $out.stderr "  my notes.md" "the path must be listed whole:"
    })

    # ── Gate robustness ─────────────────────────────────────────────────────
    (run-case "gate/script-file-path-runs-the-file" {
        let root = (make-shared-repo "gatefile")
        let bin = (make-stubs $root "closed")
        make-branch $root "67" "0" [{path: "src/task.txt", content: "task work\n"}]
        # Quoting that would need several escape layers inline, living in a
        # file where it is just a line. Not executable: must still run.
        let gate = ($root | path join ".." | path expand | path join $"gate-(random chars -l 8).sh")
        "test \"$(printf '%s' 'a \"b\" c')\" = 'a \"b\" c' && echo ran > gate-ran.txt\n" | save -f $gate

        let out = (run-land $root $bin "67" "0" $gate)

        assert-eq $out.exit_code 0 $"the gate file should pass: ($out.stderr)"
        assert-eq (read-file $root "gate-ran.txt") "ran\n" "the gate file did not run in the repo root:"
    })

    (run-case "gate/failing-script-file-rejects-and-reports-exit" {
        let root = (make-shared-repo "gatefail")
        let bin = (make-stubs $root "closed")
        make-branch $root "68" "0" [{path: "src/task.txt", content: "task work\n"}]
        let gate = ($root | path join ".." | path expand | path join $"gate-(random chars -l 8).sh")
        "exit 7\n" | save -f $gate

        let out = (run-land $root $bin "68" "0" $gate)
        let calls = (read-log $root "bd-calls.log" | str join "\n")

        assert-eq $out.exit_code 2 "a failing gate file must reject:"
        assert-str-contains $calls "exit 7" "the note must carry the gate's exit code:"
    })

    (run-case "gate/does-not-inherit-nounset" {
        let root = (make-shared-repo "nounset")
        let bin = (make-stubs $root "closed")
        make-branch $root "69" "0" [{path: "src/task.txt", content: "task work\n"}]
        # The script runs under `set -u`; a gate referencing an unset var used
        # to die inside eval, a false POST-MERGE FAIL. The gate gets a clean shell.
        let out = (run-land $root $bin "69" "0" "test -z \"$LAND_SURELY_UNSET_VAR\"")

        assert-eq $out.exit_code 0 $"a gate must not inherit the script's set -u: ($out.stderr)"
    })
]

$cases | to json
