#!/usr/bin/env nu
# Regression cases for land-bd-task.sh's dep-sync directory and status
# ownership (dotfiles-v8fw / dotfiles-luzj).
#
# The bug these pin cost two real incidents and was invisible for five days
# because nothing covered this script at all: `go mod download` ran at the
# repo ROOT for a lockfile living in a subdirectory, so in a repo with seven
# Go modules and no root `go.mod` it died with "go: no modules specified",
# hard-reset a good merge, and reopened a task the auditor had just closed.
#
# Every case runs the real script as a subprocess against a throwaway git repo
# with a stubbed `bd` and `go` on PATH. The `go` stub logs its `$PWD`, because
# the defect was never in WHICH command ran — it was in WHERE.

use harness.nu *

let cases = [
    # ── dotfiles-v8fw: the sync runs in the lockfile's own directory ────────
    (run-case "dep-sync/nested-module-syncs-in-its-own-dir" {
        let root = (make-repo "nested")
        let bin = (make-stubs $root "closed")
        make-branch $root "42" "0" [
            {path: "agent-monitor/go.mod", content: "module agent-monitor\n"}
            {path: "agent-monitor/go.sum", content: "example.com/dep v1.0.0 h1:abc=\n"}
        ]

        let out = (run-land $root $bin "42" "0")
        let cwds = (read-log $root "go-cwd.log")

        assert-eq $out.exit_code 0 "a nested-module lockfile must not fail the land:"
        assert-eq ($cwds | length) 1 "exactly one sync should have run:"
        # The load-bearing assertion. Before the fix this was $root.
        assert-eq ($cwds | first | path basename) "agent-monitor" "sync ran in the wrong directory:"
    })

    (run-case "dep-sync/root-lockfile-still-syncs-at-the-root" {
        let root = (make-repo "rootlock")
        let bin = (make-stubs $root "closed")
        make-branch $root "43" "0" [
            {path: "go.mod", content: "module rootmod\n"}
            {path: "go.sum", content: "example.com/dep v1.0.0 h1:abc=\n"}
        ]

        let out = (run-land $root $bin "43" "0")
        let cwds = (read-log $root "go-cwd.log")

        assert-eq $out.exit_code 0 "a root lockfile must still land:"
        assert-eq ($cwds | length) 1 "exactly one sync should have run:"
        # `.` resolves back to the repo root — the case the old code got right
        # and which must not regress while fixing the nested one.
        assert-eq ($cwds | first | path expand) ($root | path expand) "root sync ran elsewhere:"
    })

    (run-case "dep-sync/two-modules-both-sync" {
        let root = (make-repo "twomod")
        let bin = (make-stubs $root "closed")
        make-branch $root "44" "0" [
            {path: "alpha/go.mod", content: "module alpha\n"}
            {path: "alpha/go.sum", content: "example.com/a v1.0.0 h1:a=\n"}
            {path: "beta/go.mod", content: "module beta\n"}
            {path: "beta/go.sum", content: "example.com/b v1.0.0 h1:b=\n"}
        ]

        let out = (run-land $root $bin "44" "0")
        let dirs = (read-log $root "go-cwd.log" | each {|d| $d | path basename } | sort)

        assert-eq $out.exit_code 0 "two changed lockfiles must still land:"
        # The old code returned after the FIRST match, leaving the second
        # module's deps stale — a latent second bug, not a hypothetical.
        assert-eq $dirs ["alpha" "beta"] "both modules should have been synced:"
    })

    (run-case "dep-sync/no-lockfile-change-runs-nothing" {
        let root = (make-repo "nolock")
        let bin = (make-stubs $root "closed")
        make-branch $root "45" "0" [{path: "src/main.go", content: "package main\n"}]

        let out = (run-land $root $bin "45" "0")

        assert-eq $out.exit_code 0 "a source-only merge must land:"
        assert-eq (read-log $root "go-cwd.log" | length) 0 "dep sync must not run without a lockfile change:"
    })

    # ── dotfiles-luzj second failure mode: the rollback is loud ─────────────
    (run-case "status/rollback-says-it-reopened-a-closed-task" {
        let root = (make-repo "reopen")
        let bin = (make-stubs $root "closed")
        make-go-fail $root $bin
        make-branch $root "46" "0" [
            {path: "mod/go.mod", content: "module mod\n"}
            {path: "mod/go.sum", content: "example.com/dep v1.0.0 h1:abc=\n"}
        ]

        let out = (run-land $root $bin "46" "0")
        let calls = (read-log $root "bd-calls.log" | str join "\n")

        assert-eq $out.exit_code 2 "a failing dep sync must reject the land:"
        assert-str-contains $calls "POST-MERGE FAIL (dep sync)" "the rollback note is missing:"
        assert-str-contains $calls "mod" "the note should name the directory the sync failed in:"
        # The silent half of the incident: the script undid an auditor's close
        # and said nothing about it.
        assert-str-contains $calls "REOPENED" "the note must say it undid a close:"
    })

    (run-case "status/rollback-on-an-open-task-does-not-claim-a-reopen" {
        let root = (make-repo "openrollback")
        let bin = (make-stubs $root "in_progress")
        make-go-fail $root $bin
        make-branch $root "47" "0" [
            {path: "mod/go.mod", content: "module mod\n"}
            {path: "mod/go.sum", content: "example.com/dep v1.0.0 h1:abc=\n"}
        ]

        let out = (run-land $root $bin "47" "0")
        let calls = (read-log $root "bd-calls.log" | str join "\n")

        assert-eq $out.exit_code 2 "a failing dep sync must still reject:"
        # Nothing was closed, so claiming a reopen would be a lie — the note
        # has to be accurate in both directions, not merely loud in one.
        assert-str-excludes $calls "REOPENED" "must not claim a reopen when the task was already open:"
    })

    (run-case "status/successful-land-flags-a-task-left-open" {
        let root = (make-repo "leftopen")
        let bin = (make-stubs $root "in_progress")
        make-branch $root "48" "0" [{path: "src/main.go", content: "package main\n"}]

        let out = (run-land $root $bin "48" "0")

        assert-eq $out.exit_code 0 "the land itself succeeded:"
        # The exact state that went unnoticed on dotfiles-rsdg.2: merge on
        # base, task still open, nothing saying so.
        assert-str-contains $out.stdout "not closed" "a successful land must flag an un-closed task:"
    })

    (run-case "status/successful-land-on-a-closed-task-is-quiet" {
        let root = (make-repo "quiet")
        let bin = (make-stubs $root "closed")
        make-branch $root "49" "0" [{path: "src/main.go", content: "package main\n"}]

        let out = (run-land $root $bin "49" "0")

        assert-eq $out.exit_code 0 "the land succeeded:"
        # The normal path must stay quiet, or the warning becomes noise every
        # auditor learns to skip.
        assert-str-excludes $out.stdout "not closed" "the happy path must not warn:"
    })
]

$cases | to json
