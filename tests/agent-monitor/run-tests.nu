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

# --- the --once pipe contract, re-checked one altitude up (sp032 T7) -------
#
# TestRunOnce_NoRawModeNoAltScreen_ExitsCleanly already pins this inside the
# Go suite above: runOnce writes into a bytes.Buffer and the test rejects a
# 0x1b byte. This case asserts the same contract against the artifact that
# actually ships -- it builds the real binary, runs `agent-monitor --once`
# with stdout attached to a PIPE rather than a terminal, and searches the raw
# bytes for 0x1b. dotfiles-r9ty is the precedent for why once is not enough:
# a unit test stayed green while the real terminal path was broken. ft016's
# `--once` contract is "composes in a pipe", and a pipe is a property of the
# process, not of the seam, so it is worth checking on the process.
print ""
print $"(ansi cyan)--once pipe contract(ansi reset)"

let scratch = (mktemp -d -t "agent-monitor-pipe-XXXXXX")
let bin = ($scratch | path join "agent-monitor")
let stubs = ($scratch | path join "stubs")
mkdir $stubs

# agent-census / pi-worker stand-ins. An empty roster and an empty message
# list still render a full frame, and keep this case off the real samplers
# (and off whatever agents happen to be running on the machine).
for stub in ["agent-census" "pi-worker"] {
    let p = ($stubs | path join $stub)
    "#!/bin/sh\necho '[]'\n" | save -f $p
    ^chmod +x $p
}

mut pipe_failures = []

let build = (with-env {CGO_ENABLED: "0"} {
    do { ^go build "-C" $root "-o" $bin "./cmd/agent-monitor" } | complete
})

if $build.exit_code != 0 {
    $pipe_failures = ($pipe_failures | append $"go build exit ($build.exit_code): ($build.stderr)")
} else {
    # `complete` gives the child a pipe for stdout, which is exactly the
    # non-tty this contract is about.
    let run = (with-env {PATH: ($env.PATH | prepend $stubs)} {
        do { ^$bin --once } | complete
    })
    let esc = ($run.stdout | into binary | bytes index-of 0x[1b])

    if $run.exit_code != 0 {
        $pipe_failures = ($pipe_failures | append $"--once exit ($run.exit_code): ($run.stderr)")
    }
    if ($run.stdout | is-empty) {
        $pipe_failures = ($pipe_failures | append "--once wrote nothing to the pipe")
    }
    if $esc >= 0 {
        $pipe_failures = ($pipe_failures | append $"--once emitted an ESC byte at offset ($esc)")
    }
}

rm -rf $scratch

if ($pipe_failures | is-not-empty) {
    for why in $pipe_failures {
        print $"(ansi red)FAIL  (ansi reset)--once pipe contract — ($why)"
    }
    print ""
    print $"(ansi red)SUITE FAILED(ansi reset) — the --once pipe contract"
    exit 1
}

print $"(ansi green)  ok  (ansi reset)--once piped to a non-tty contains no 0x1b byte"

print ""
print $"(ansi green)all agent-monitor cases passed(ansi reset)"
exit 0
