#!/usr/bin/env nu
# Test runner for the infinifu lifecycle smoke's checker (sp037 T5).
#
#   nu tests/infinifu/run-tests.nu
#
# Exit status is 0 when every case passes, 1 when any case fails — usable as
# a merge gate.
#
# One suite today: smoke-cases.nu, which exercises check-smoke-run (the pure
# checker lifecycle-smoke.nu exports) over fixture states. It runs as a
# subprocess so a module that fails to PARSE reports as one failed suite
# instead of taking the whole runner down — same shape as
# tests/pi-worker/run-tests.nu and tests/work-merge/run-tests.nu.
#
# The live smoke itself (lifecycle-smoke.nu's `main`, run with --runtime
# claude|pi) is deliberately absent from SUITES: it mints a real bd task and
# drives real workers, so it is sp037 Task 6, run by hand, not part of this
# gate. See lifecycle-smoke.nu's header for why: a gate that spends model
# tokens is a gate people learn to skip.

const SUITES = [
    [label, file];
    ["smoke-checker", "smoke-cases.nu"]
]

def run-subsuite [label: string, file: string] {
    let out = (do { ^$nu.current-exe ($env.FILE_PWD | path join $file) } | complete)
    if $out.exit_code == 0 {
        $out.stdout | from json
    } else {
        [{name: $"($label)/<suite crashed>", status: "FAIL", detail: ($out.stderr | str substring 0..600)}]
    }
}

print $"(ansi cyan)infinifu lifecycle-smoke suite(ansi reset)"
print ""

let results = ($SUITES | each {|s| run-subsuite $s.label $s.file } | flatten)

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

print ""
print $"($passed) passed, ($failed) failed"

if $failed > 0 {
    print $"(ansi red)SUITE FAILED(ansi reset)"
    exit 1
}
exit 0
