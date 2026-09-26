#!/usr/bin/env nu
# Test runner for work-merge's land-bd-task.sh (dotfiles-v8fw / dotfiles-luzj).
#
#   nu tests/work-merge/run-tests.nu
#
# Exit status is 0 when every case passes, 1 when any case fails.
#
# One suite today. It runs as a subprocess so a module that fails to PARSE
# reports as one failed suite instead of taking the runner down with it —
# same shape as tests/go-stale/run-tests.nu.

use harness.nu *

const SUITES = [
    [label, file];
    ["land", "land-cases.nu"]
    ["safety", "safety-cases.nu"]
]

def run-subsuite [label: string, file: string] {
    let out = (do { ^$nu.current-exe ($env.FILE_PWD | path join $file) } | complete)
    if $out.exit_code == 0 {
        $out.stdout | from json
    } else {
        [{name: $"($label)/<suite crashed>", status: "FAIL", detail: ($out.stderr | str substring 0..600)}]
    }
}

print $"(ansi cyan)work-merge suite(ansi reset)"
print ""

let harness_cases = [
    (run-case "harness/detects-inequality" {
        let threw = (try { assert-eq 1 2; false } catch { true })
        if not $threw { error make {msg: "assert-eq must reject unequal values"} }
    })
    (run-case "harness/excludes-detects-presence" {
        let threw = (try { assert-str-excludes "abc" "b"; false } catch { true })
        if not $threw { error make {msg: "assert-str-excludes must reject a present needle"} }
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

print ""
print $"($passed) passed, ($failed) failed"

if $failed > 0 {
    print $"(ansi red)SUITE FAILED(ansi reset)"
    exit 1
}
exit 0
