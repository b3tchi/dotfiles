#!/usr/bin/env nu
# Test runner for the infinifu worker bus (ft014 / sp028).
#
#   nu tests/infinifu-worker/run-tests.nu
#
# Exit status is 0 when every case passes and 1 when any case fails, so this is
# usable as a merge gate.
#
# No tmux server and no Pi process is required. The schema, transition and
# static suites are pure; the bus suite does real filesystem IO but each case
# runs against its own XDG_RUNTIME_DIR under the temp dir, so the suite never
# touches a live session's runtime directory and cases cannot leak into each
# other. A gate that needed a live tmux server would only ever run on one
# machine, and a protocol nobody can check is a protocol that drifts.
#
# The live half is `live-smoke.nu`, run by hand: two real Pi workers, real
# tmux, real worktrees, real tokens. It is deliberately absent from SUITES —
# a gate that spends money is a gate people learn to skip.
#
# Suites run as subprocesses so a module that fails to PARSE reports as one
# failed suite instead of taking the runner down with it.

use harness.nu *

const SUITES = [
    [label, file];
    ["schema",     "schema-cases.nu"]
    ["transition", "transition-cases.nu"]
    ["static",     "static-cases.nu"]
    ["bus",        "bus-cases.nu"]
    ["worktree",   "worktree-cases.nu"]
    ["pi-bridge",  "pi-bridge-cases.nu"]
    ["pipeline",   "pipeline-cases.nu"]
    ["live-tmux",  "live-tmux-cases.nu"]
    ["install",    "install-cases.nu"]
    ["acceptance", "acceptance-cases.nu"]
]

def run-subsuite [label: string, file: string] {
    let out = (do { ^$nu.current-exe ($env.FILE_PWD | path join $file) } | complete)
    if $out.exit_code == 0 {
        $out.stdout | from json
    } else {
        [{name: $"($label)/<suite crashed>", status: "FAIL", detail: ($out.stderr | str substring 0..600)}]
    }
}

print $"(ansi cyan)infinifu-worker protocol suite(ansi reset)"
print ""

# The assertions guard everything else, so they are checked first.
let harness_cases = [
    (run-case "harness/detects-inequality" {
        assert-throws { assert-eq 1 2 } "assert-eq must reject unequal values"
    })
    (run-case "harness/passes-on-equal" { assert-eq 1 1 })
    (run-case "harness/assert-true-rejects-false" {
        assert-throws { assert-true false "x" } "assert-true must reject false"
    })
    (run-case "harness/assert-rejects-needs-a-throw" {
        assert-throws { assert-rejects {|| 1 } "reason" "x" } "assert-rejects must fail when nothing throws"
    })
    # A suite that leaks on the failure path leaks precisely when it is being
    # used most: this box was found holding 42 live tmux servers, 40 dead
    # sockets and 67 MB of git worktrees from one afternoon of red runs, because
    # teardown written as the last statement of a case is skipped by a failing
    # assertion. run-case now sandboxes and reaps, so the leak is impossible
    # rather than remembered.
    (run-case "harness/a-failing-case-leaves-no-fixtures-behind" {
        # The inner case's path is written OUT of the closure through a file,
        # because the assertion has to run after the reaping.
        let witness = ([$nu.temp-dir $"piw-witness-(random chars --length 6)"] | path join)
        let inner = (run-case "inner/deliberately-fails" {
            let repo = (make-repo "leak-probe")
            let runtime = (make-runtime "leak-probe")
            [$repo $runtime] | str join "\n" | save -f $witness
            assert-eq 1 2 "this case is meant to fail"
        })
        assert-eq $inner.status "FAIL" "the inner case must have failed"
        let paths = (open $witness | lines)
        rm -f $witness
        assert-eq ($paths | length) 2 ""
        for p in $paths {
            assert-true (not ($p | path exists)) $"($p) survived a failing case"
            assert-true ($p | str contains "piw-case") $"($p) was not created in a sandbox"
        }
    })

    (run-case "harness/a-failing-case-leaves-no-tmux-server-behind" {
        # The expensive half of the leak: a socket lives outside the sandbox, so
        # the harness can only kill what was registered through new-tmux-socket.
        let witness = ([$nu.temp-dir $"piw-witness-(random chars --length 6)"] | path join)
        let inner = (run-case "inner/leaves-a-server" {
            let socket = (new-tmux-socket "leak-probe")
            ^tmux -L $socket new-session -d -s "probe" -n "main"
            $socket | save -f $witness
            assert-eq 1 2 "this case is meant to fail"
        })
        assert-eq $inner.status "FAIL" ""
        let socket = (open $witness | str trim)
        rm -f $witness
        let alive = (do { ^tmux -L $socket list-sessions } | complete | get exit_code)
        assert-true ($alive != 0) $"the server on ($socket) survived a failing case"
    })

    (run-case "harness/assert-rejects-checks-the-reason" {
        # A validator that throws the wrong reason is as bad as one that does
        # not throw: the operator still cannot tell what to fix.
        assert-throws {
            assert-rejects { error make {msg: "something else"} } "sequence" "x"
        } "assert-rejects must fail when the reason does not match"
    })
]

let results = ($harness_cases ++ ($SUITES | each {|s| run-subsuite $s.label $s.file } | flatten))

for r in $results {
    let mark = match $r.status {
        "pass" => $"(ansi green)  ok  (ansi reset)"
        "FAIL" => $"(ansi red)FAIL  (ansi reset)"
        _      => $"(ansi yellow) pend (ansi reset)"
    }
    print $"($mark) ($r.name)"
    if ($r.detail | is-not-empty) and $r.status != "pass" {
        print $"        ($r.detail)"
    }
}

let passed = ($results | where status == "pass" | length)
let failed = ($results | where status == "FAIL" | length)
let pend   = ($results | where status == "PENDING" | length)

print ""
print $"($passed) passed, ($failed) failed, ($pend) pending"

if $failed > 0 {
    print $"(ansi red)SUITE FAILED(ansi reset)"
    exit 1
}
exit 0
