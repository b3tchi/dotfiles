#!/usr/bin/env nu
# Test runner for agent-monitor (ft016 / sp030 T10).
#
#   nu tests/agent-monitor/run-tests.nu
#
# Exit status is 0 when every case passes and 1 when any fails, so this
# composes as a merge gate the same way every other tests/<name>/run-tests.nu
# does (see tests/pi-worker/run-tests.nu, tests/agent-census/run-tests.nu).
#
# agent-monitor is a pure Go module with no nushell subsuites of its own —
# unlike those two runners, there is no per-case JSON protocol to reimplement
# here, because `go test` already IS the per-case runner (each Go test
# function is one case, `-race` catches the concurrency bugs this module
# actually has to worry about — the shared Restorer across goroutines, the
# two-clock RunDualTicked select). This file re-prints `go test -v`'s own
# --- PASS/--- FAIL lines through the same ok/FAIL visual language as the
# nu suites for a consistent read across `tests/*/run-tests.nu`, but the
# PASS/FAIL DECISION is always `go test`'s own exit code — never re-derived
# by string-matching its -v output, which is not a stable contract to parse.
def module_root [] {
    $env.FILE_PWD | path join ".." ".." "agent-monitor"
}

let root = (module_root)
print $"(ansi cyan)agent-monitor suite(ansi reset)  root=($root)"
print ""

let out = (do { ^go test "-C" $root "./..." "-race" "-v" } | complete)

for line in ($out.stdout | lines) {
    if ($line | str starts-with "--- PASS") {
        print $"(ansi green)  ok  (ansi reset)($line | str replace '--- PASS: ' '')"
    } else if ($line | str starts-with "--- FAIL") {
        print $"(ansi red)FAIL  (ansi reset)($line | str replace '--- FAIL: ' '')"
    } else if ($line | str starts-with "FAIL") or ($line | str starts-with "ok  ") {
        print $"(ansi dark_gray)($line)(ansi reset)"
    }
}

if $out.exit_code != 0 {
    print ""
    if ($out.stderr | is-not-empty) {
        print $out.stderr
    }
    print $"(ansi red)SUITE FAILED(ansi reset) — go test exit code ($out.exit_code)"
    exit 1
}

print ""
print $"(ansi green)all agent-monitor go tests passed(ansi reset)"
exit 0
