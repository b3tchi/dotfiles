# Shared test harness for the agent-census suites.
#
# Assertions, the case runner, fixture loading, and the stub-sandbox helpers
# live here once. Every suite imports them:
#
#   use harness.nu *
#
# The assertions are themselves tested, in run-tests.nu's `harness/*` cases —
# an assertion that has stopped detecting failure makes every other case in
# the repository decoration, so it is the one thing that must not be taken on
# trust.

# The fixtures use this root. Deliberately NOT $HOME: the registry paths and
# the agent `cwd` values have to line up for attribution to mean anything, and
# they must line up the same way on every machine.
export const FIXTURE_ROOT = "/home/dev"

# ------------------------------------------------------------- assertions

export def assert-eq [actual, expected, msg: string = ""] {
    if $actual != $expected {
        error make {msg: $"expected ($expected | to nuon), got ($actual | to nuon). ($msg)"}
    }
}

export def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $"assertion failed: ($msg)"} }
}

export def assert-throws [body: closure, msg: string] {
    let threw = (try { do $body; false } catch { true })
    if not $threw { error make {msg: $"expected a failure but none was raised: ($msg)"} }
}

# ----------------------------------------------------------- case running

export def run-case [name: string, body: closure] {
    try { do $body; {name: $name, status: "pass", detail: ""} } catch {|e| {name: $name, status: "FAIL", detail: $e.msg} }
}

export def pending [name: string, why: string] {
    {name: $name, status: "PENDING", detail: $why}
}

# ------------------------------------------------------- fixture loading

# Callers pass their own $env.FILE_PWD: a module cannot see its importer's
# script directory, and every suite sits beside the fixtures dir.
export def fixture-dir [caller_dir: string]: nothing -> string {
    $caller_dir | path join "fixtures"
}

export def load-json [caller_dir: string, name: string] {
    open --raw (fixture-dir $caller_dir | path join $name) | from json
}

# Text fixtures carry `#` provenance headers (JSON cannot — see SOURCES.md).
# Strip them, drop blank lines, and remove any CR left by a capture that
# crossed a Windows pipe.
export def load-lines [caller_dir: string, name: string]: nothing -> list<string> {
    open --raw (fixture-dir $caller_dir | path join $name)
    | lines
    | each {|l| $l | str replace --regex '\r$' '' }
    | where {|l| not ($l | str starts-with "#") }
    | where {|l| ($l | str length) > 0 }
}

# --------------------------------------------------------- stub sandboxes

# Write an executable stub into a sandbox's bin/.
#
# Stub bodies run on a PATH containing ONLY that bin, so they may use bash
# builtins and absolute paths only — no bare `cat`, `touch` or `sleep`. This
# has bitten three times; the shebang is absolute for the same reason (`env`
# itself needs PATH to find `bash`).
export def write-stub [root: string, name: string, body: string] {
    let p = ([$root "bin" $name] | path join)
    $"#!/bin/bash\n($body)\n" | save -f $p
    chmod +x $p
}

export def make-sandbox [prefix: string, tag: string]: nothing -> string {
    let root = ([$nu.temp-dir $"agent-census-($prefix)-($tag)"] | path join)
    rm -rf $root
    mkdir ($root | path join "bin")
    $root
}

# Run a closure with ONLY the sandbox bin on PATH, so a probe that reaches for
# the real claude/tmux/ps finds the stub or nothing at all.
#
# Deliberately does NOT add nushell's own directory: nu lives in /usr/sbin on
# this system, which also holds tmux and ps, so including it would quietly
# hand the probes the real binaries and make "the binary is absent" pass for
# the wrong reason. nu is already running; it need not be on PATH.
export def with-stub-path [root: string, body: closure] {
    with-env {PATH: [([$root "bin"] | path join)]} { do $body }
}
