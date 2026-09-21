#!/usr/bin/env nu
# Unit tests for lifecycle-smoke.nu's `check-smoke-run` checker (sp037 T5).
#
# check-smoke-run is a PURE function over an already-gathered state record —
# no git, no bd, no filesystem, no tmux, no pi-worker. That is what lets this
# file drive it over fixture states without spawning anything: a real
# end-to-end run costs model tokens and is deliberately Task 6, run rarely.
# If this file is the only thing standing between the checker and bit rot,
# every failure mode below has to be pinned, not just the happy path.
#
# Run as a subprocess by run-tests.nu and prints its results as JSON, so a
# module that fails to PARSE reports as one failed suite rather than taking
# the whole runner down — same convention as tests/pi-worker/*.
#
#   nu tests/infinifu/smoke-cases.nu | from json

use lifecycle-smoke.nu [check-smoke-run]

# ------------------------------------------------------- local mini-harness
#
# No tests/infinifu/harness.nu exists (this task's files_touched is exactly
# lifecycle-smoke.nu, smoke-cases.nu, run-tests.nu), so the handful of
# assertion primitives this file needs live here, private to it.

def assert-eq [actual, expected, msg: string = ""] {
    if $actual != $expected {
        error make {msg: $"expected ($expected | to nuon), got ($actual | to nuon). ($msg)"}
    }
}

def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $"assertion failed: ($msg)"} }
}

def run-case [name: string, body: closure] {
    try {
        do $body
        {name: $name, status: "pass", detail: ""}
    } catch {|e|
        {name: $name, status: "FAIL", detail: $e.msg}
    }
}

# Failure names only, sorted, so a case can assert the exact SET of failures
# without depending on the order check-smoke-run happens to emit them in.
def failure-names [outcome: record] {
    $outcome.failures | get name | sort
}

# ------------------------------------------------------------- fixture data

# A fully correct run: every one of the five assertions holds. Every failure
# fixture below is this record with exactly the fields needed to break one
# (or more) assertion changed — never a hand-rolled fresh record — so a
# fixture that "accidentally" also breaks another assertion is caught
# immediately by that case's exact failure-set assertion.
let good_task_id = "dotfiles-9k2m"
let good_ts = "20260921120000000001"

def good-state [] {
    {
        task_id: "dotfiles-9k2m"
        observed_branch: "bd-dotfiles-9k2m.0"
        worktree_exists: false
        branch_exists: false
        smoke_ts: "20260921120000000001"
        expected_header: "# infinifu lifecycle smoke"
        smoke_file_content: "# infinifu lifecycle smoke\n\nwritten by the smoke worker\n"
        task_status: "closed"
        task_notes: "IMPLEMENTED: wrote the smoke file.\n\nAUDIT: verified header and closed after work-audit review."
        bus_result: {status: "complete", summary: "wrote the smoke file and merged", validation: "PASS"}
    }
}

let results = [
    # ---------------------------------------------------------- passing case
    (run-case "correct-run-all-five-pass" {
        let outcome = (check-smoke-run (good-state))
        assert-true $outcome.ok "a fully correct state must pass"
        assert-eq $outcome.failures [] "a fully correct state must report no failures"
    })

    # ------------------------------------------------- one broken assertion,
    # ------------------------------------------------- each named alone
    (run-case "wrong-branch-dotfiles-41fr-shape-fails-only-branch" {
        # The real incident this checker exists to catch: dotfiles-41fr
        # landed on the literal branch `wk-timestamp-file.0` instead of its
        # own bd branch, and nobody noticed until someone read the notes.
        let state = (good-state | merge {observed_branch: "wk-timestamp-file.0"})
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "a wk-timestamp-file.0 branch must not pass"
        assert-eq (failure-names $outcome) ["branch"] "only the branch assertion should fail"
    })

    (run-case "branch-assertion-binds-to-the-task-id-not-just-the-shape" {
        # bd-other.0 matches the bd-<id>.<N> SHAPE exactly, but `other` is not
        # this task's own id — a checker that only pattern-matched the shape
        # would wave this through.
        let state = (good-state | merge {observed_branch: "bd-other.0"})
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "bd-other.0 must fail for a task that is not 'other'"
        assert-eq (failure-names $outcome) ["branch"] "only the branch assertion should fail"
    })

    (run-case "task-left-in-progress-fails-only-task-closed" {
        let state = (good-state | merge {task_status: "in_progress"})
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "an in_progress task must not pass"
        assert-eq (failure-names $outcome) ["task-closed"] "only the task-closed assertion should fail"
    })

    (run-case "closed-without-audit-evidence-fails-only-task-closed" {
        # Closed is not enough on its own — the notes must carry audit
        # evidence, or `closed` just means "implementer thinks it's done".
        let state = (good-state | merge {task_notes: "IMPLEMENTED: wrote the smoke file."})
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "closed with no audit evidence in notes must not pass"
        assert-eq (failure-names $outcome) ["task-closed"] "only the task-closed assertion should fail"
    })

    (run-case "worktree-still-present-fails-only-cleanup" {
        let state = (good-state | merge {worktree_exists: true})
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "a still-present worktree must not pass"
        assert-eq (failure-names $outcome) ["cleanup"] "only the cleanup assertion should fail"
    })

    (run-case "branch-still-present-fails-only-cleanup" {
        let state = (good-state | merge {branch_exists: true})
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "a still-present branch must not pass"
        assert-eq (failure-names $outcome) ["cleanup"] "only the cleanup assertion should fail"
    })

    (run-case "prose-summary-with-no-validation-field-fails-only-typed-result" {
        # adr0027: completion is read from a typed field, never from prose.
        # A record with only `summary` is exactly the shape a model produces
        # when it reports success without having run its validation.
        let state = (good-state | merge {
            bus_result: {summary: "all done, everything worked great"}
        })
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "a prose-only summary with no validation field must not pass"
        assert-eq (failure-names $outcome) ["typed-result"] "only the typed-result assertion should fail"
    })

    (run-case "typed-result-missing-status-fails-only-typed-result" {
        let state = (good-state | merge {
            bus_result: {summary: "wrote the file", validation: "PASS"}
        })
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "a result missing status must not pass"
        assert-eq (failure-names $outcome) ["typed-result"] "only the typed-result assertion should fail"
    })

    (run-case "smoke-file-missing-fails-only-smoke-file" {
        let state = (good-state | merge {smoke_file_content: null})
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "a missing smoke file must not pass"
        assert-eq (failure-names $outcome) ["smoke-file"] "only the smoke-file assertion should fail"
    })

    (run-case "smoke-file-without-header-fails-only-smoke-file" {
        let state = (good-state | merge {smoke_file_content: "some other file, not the smoke marker\n"})
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "a file without the fixed header must not pass"
        assert-eq (failure-names $outcome) ["smoke-file"] "only the smoke-file assertion should fail"
    })

    # ---------------------------------------------------------- edge cases
    (run-case "test_checker_reports_every_failure_not_the_first" {
        # The realistic regression: a five-assertion checker degrading into a
        # first-failure-only one. Three assertions broken at once, and every
        # one of the three must be named — none of the two still-good ones.
        let state = (good-state | merge {
            observed_branch: "wk-timestamp-file.0"
            worktree_exists: true
            bus_result: {summary: "did it"}
        })
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "a triple-broken state must not pass"
        assert-eq (failure-names $outcome) ["branch" "cleanup" "typed-result"] "all three broken assertions must be named, and only those three"
    })

    (run-case "test_stale_smoke_file_does_not_satisfy_a_later_run" {
        # A previous run's file exists on base (a DIFFERENT timestamp than
        # THIS run's), but this run's own expected file does not. The
        # checker must bind to this run's exact expected path
        # (smoke-file-path $state.smoke_ts), never a glob over
        # docs/notes/lab/smoke-*.md, or a stale leftover from an earlier
        # failed run would make every later run look like it passed.
        let state = (good-state | merge {
            smoke_ts: "20260921120000000099"
            # smoke_file_content models what the DRIVER would have gathered
            # for path smoke-file-path($smoke_ts) specifically — since that
            # exact file does not exist on base for this run, the gathered
            # content is null, even though an older smoke-<earlier-ts>.md
            # file is still sitting in docs/notes/lab/ from a previous run.
            smoke_file_content: null
        })
        let outcome = (check-smoke-run $state)
        assert-true (not $outcome.ok) "a stale earlier-run file must not satisfy this run"
        assert-eq (failure-names $outcome) ["smoke-file"] "only the smoke-file assertion should fail"
    })

    # ------------------------------------------------- pure-function sanity
    (run-case "checker-never-mutates-its-input" {
        let state = (good-state)
        let before = ($state | to nuon)
        check-smoke-run $state | ignore
        assert-eq ($state | to nuon) $before "check-smoke-run must not mutate the state it was given"
    })

    (run-case "checker-is-deterministic-over-the-same-state" {
        let state = (good-state | merge {observed_branch: "wk-timestamp-file.0"})
        let a = (check-smoke-run $state)
        let b = (check-smoke-run $state)
        assert-eq $a $b "check-smoke-run must return the same verdict for the same input every time"
    })
]

print ($results | to json -r)
