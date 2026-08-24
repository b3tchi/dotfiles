#!/usr/bin/env nu
# Test runner for agent-census (ft012 / sp026).
#
# Runs with NO live agents and NO tmux server: every input comes from
# tests/agent-census/fixtures, or from stub executables on a sandboxed PATH.
# That is the point — arranging a real agent into `blocked` on demand is not
# repeatable, and a suite that needed it would only ever run on one machine.
#
#   nu tests/agent-census/run-tests.nu
#
# Exit status is 0 when every case passes, 1 when any case fails, so this is
# usable as a gate.
#
# This file orchestrates. The cases live in three suites, each invoked as a
# subprocess so that a module which fails to PARSE reports as one failed suite
# instead of taking the runner down with it:
#
#   transform-cases.nu   pure layer + fixture integrity
#   probe-cases.nu       the shell-out layer, against stubs
#   cli-cases.nu         the assembled action, end to end
#
# The only cases defined here are the harness self-tests, because an assertion
# that has stopped detecting failure would make every other case decoration.

use harness.nu *

const SUITES = [
    [label, file];
    ["transform", "transform-cases.nu"]
    ["probe",     "probe-cases.nu"]
    ["cli",       "cli-cases.nu"]
]

def run-subsuite [label: string, file: string] {
    let out = (do { ^$nu.current-exe ($env.FILE_PWD | path join $file) } | complete)
    if $out.exit_code == 0 {
        $out.stdout | from json
    } else {
        [{name: $"($label)/<suite crashed>", status: "FAIL", detail: ($out.stderr | str substring 0..600)}]
    }
}

print $"(ansi cyan)agent-census suite(ansi reset)  root=($FIXTURE_ROOT)"
print ""

let harness_cases = [
    (run-case "harness/detects-inequality" {
        assert-throws { assert-eq 1 2 } "assert-eq must reject unequal values"
    })
    (run-case "harness/detects-thrown-error" {
        assert-throws { error make {msg: "boom"} } "run-case must surface a raised error"
    })
    (run-case "harness/passes-on-equal" { assert-eq 1 1 })
    (run-case "harness/assert-true-rejects-false" {
        assert-throws { assert-true false "x" } "assert-true must reject false"
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
