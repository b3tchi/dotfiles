#!/usr/bin/env nu
# Test runner for the infinifu worker bus (ft014 / sp028).
#
#   nu tests/infinifu-worker/run-tests.nu
#
# Exit status is 0 when every case passes and 1 when any case fails, so this is
# usable as a merge gate.
#
# Every case here is pure: schemas, the state table, and static reads of shipped
# files. No tmux server, no Pi process, no runtime directory — those arrive with
# the bus implementation in sp028 T2-T4 and get their own suites. Keeping T1's
# gate free of live processes is deliberate: a contract suite that needs a tmux
# server only runs on one machine, and a protocol nobody can check is a protocol
# that drifts.
#
# Suites run as subprocesses so a module that fails to PARSE reports as one
# failed suite instead of taking the runner down with it.

use harness.nu *

const SUITES = [
    [label, file];
    ["schema",     "schema-cases.nu"]
    ["transition", "transition-cases.nu"]
    ["static",     "static-cases.nu"]
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
