#!/usr/bin/env nu
# Test runner for go-stale (dotfiles-xwg0).
#
#   nu tests/go-stale/run-tests.nu
#
# Exit status is 0 when every case passes, 1 when any case fails.
#
# Four suites, each run as a subprocess so a module that fails to PARSE
# reports as one failed suite instead of taking the runner down with it:
#
#   transform-cases.nu        pure classify-module logic, synthetic records
#   probe-cases.nu            real files/mtimes against a throwaway sandbox —
#                             the load-bearing "source newer than artifact ->
#                             STALE, named" proof
#   manifest-verify-cases.nu  the manifest-vs-dot.yaml drift check (rejection
#                             #1 gap 1) — every real shell idiom, plus a real
#                             DRIFT case
#   cli-cases.nu              the assembled `go-stale` action, end to end,
#                             including a real go-build round trip in rebuild
#                             mode

use harness.nu *

const SUITES = [
    [label, file];
    ["transform",       "transform-cases.nu"]
    ["probe",           "probe-cases.nu"]
    ["manifest-verify", "manifest-verify-cases.nu"]
    ["cli",             "cli-cases.nu"]
]

def run-subsuite [label: string, file: string] {
    let out = (do { ^$nu.current-exe ($env.FILE_PWD | path join $file) } | complete)
    if $out.exit_code == 0 {
        $out.stdout | from json
    } else {
        [{name: $"($label)/<suite crashed>", status: "FAIL", detail: ($out.stderr | str substring 0..600)}]
    }
}

print $"(ansi cyan)go-stale suite(ansi reset)"
print ""

let harness_cases = [
    (run-case "harness/detects-inequality" {
        let threw = (try { assert-eq 1 2; false } catch { true })
        if not $threw { error make {msg: "assert-eq must reject unequal values"} }
    })
    (run-case "harness/passes-on-equal" { assert-eq 1 1 })
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
