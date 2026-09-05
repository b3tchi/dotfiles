# Shared test harness for the infinifu-worker suites (ft014 / sp028).
#
# Assertions and the case runner live here once; every suite imports them:
#
#   use harness.nu *
#
# The assertions are themselves exercised in run-tests.nu's `harness/*` cases.
# An assertion that has stopped detecting failure turns every other case in
# the suite into decoration, so it is the one thing not taken on trust.
#
# Deliberately mirrors tests/agent-census/harness.nu rather than inventing a
# second convention.

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

# A rejection must say WHY. A validator that throws a bare "error" tells the
# operator nothing at 3am, so the reason is part of the contract.
export def assert-rejects [body: closure, expect: string, msg: string] {
    let outcome = (try { do $body; {threw: false, reason: ""} } catch {|e| {threw: true, reason: $e.msg} })
    if not $outcome.threw {
        error make {msg: $"expected rejection but none was raised: ($msg)"}
    }
    if not ($outcome.reason | str lowercase | str contains ($expect | str lowercase)) {
        error make {msg: $"rejection reason must mention '($expect)', got: ($outcome.reason). ($msg)"}
    }
}

# ----------------------------------------------------------- case running

export def run-case [name: string, body: closure] {
    try { do $body; {name: $name, status: "pass", detail: ""} } catch {|e| {name: $name, status: "FAIL", detail: $e.msg} }
}

export def pending [name: string, why: string] {
    {name: $name, status: "PENDING", detail: $why}
}

# ------------------------------------------------------------ repo paths

# Suites sit at <repo>/tests/infinifu-worker/; the shipped protocol module and
# the Pi extension are two and three levels up from there.
export def repo-root [caller_dir: string]: nothing -> string {
    $caller_dir | path dirname | path dirname
}

export def worker-script [caller_dir: string]: nothing -> string {
    repo-root $caller_dir
    | path join "claude" "marketplace" "plugins" "infinifu" "scripts" "infinifu-worker.nu"
}

export def pi-extension [caller_dir: string]: nothing -> string {
    repo-root $caller_dir
    | path join "claude" "marketplace" "plugins" "infinifu" "extensions" "pi.ts"
}

# ------------------------------------------------------------- envelopes

# A minimal well-formed envelope of each kind. Cases mutate one field at a
# time so a rejection is attributable to that field and nothing else.
export def sample-envelope [kind: string]: nothing -> record {
    let base = {
        protocol: 1
        sequence: 1
        run: "run-42"
        uid: "impl-dotfiles-963w.1-a1"
        kind: $kind
        created: "2026-09-05T10:00:00Z"
    }
    let payload = match $kind {
        "inbox" => {stage: "work-do", task: "dotfiles-963w.1"}
        "result" => {
            status: "complete"
            summary: "protocol module landed"
            validation: "PASS"
            window: "impl-dotfiles-963w.1@dotfiles"
            session: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
            resume: "pi --session 0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        }
        "error" => {code: "protocol_error", detail: "agent settled without calling the result tool"}
        _ => {}
    }
    $base | insert payload $payload
}

# --------------------------------------------------------- bus sandboxes

# Every bus suite runs against its own XDG_RUNTIME_DIR. The bus keys entirely
# off that variable, so an isolated one gives each case a private universe —
# no shared state between cases, and nothing written near the real runtime dir
# of a live session.
export def make-runtime [tag: string]: nothing -> string {
    let root = ([$nu.temp-dir $"infinifu-worker-test-($tag)-(random chars --length 6)"] | path join)
    rm -rf $root
    mkdir $root
    chmod 700 $root
    $root
}

export def with-runtime [root: string, body: closure] {
    with-env {XDG_RUNTIME_DIR: $root} { do $body }
}

# File mode as the `rwx` string nushell reports, e.g. "rw-------".
export def mode-of [path: string]: nothing -> string {
    ls -l $path | get 0.mode
}

# `ls -ld` returns nothing on this nushell, so a directory's own mode has to be
# read from its parent's listing.
export def dir-mode-of [path: string]: nothing -> string {
    let parent = ($path | path dirname)
    let entry = (ls -l $parent | where name == $path)
    if ($entry | is-empty) { error make {msg: $"no such directory: ($path)"} }
    $entry | get 0.mode
}

# ------------------------------------------------------- git repo fixtures

# A throwaway repository with one commit on `main`. Worktree allocation is only
# meaningful against a real repo — `git worktree` has enough behavior of its own
# (locks, prunable registrations, branch-without-directory) that faking it would
# test the fake.
export def make-repo [tag: string]: nothing -> string {
    let root = ([$nu.temp-dir $"infinifu-worker-repo-($tag)-(random chars --length 6)"] | path join)
    rm -rf $root
    mkdir $root
    ^git -C $root init -q -b main
    ^git -C $root config user.email "test@example.com"
    ^git -C $root config user.name "Test"
    "seed\n" | save -f ($root | path join "README.md")
    ^git -C $root add -A
    ^git -C $root commit -q -m "seed"
    $root
}

export def git-in [repo: string, ...args: string]: nothing -> string {
    ^git -C $repo ...$args | str trim
}
