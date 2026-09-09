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

# Every suite runs against a fixture registry, never a real installation. The
# names are deliberately not any consumer's: the bus treats them as opaque, and
# a suite that spoke one framework's vocabulary would quietly re-couple them.
export-env {
    $env.PI_WORKER_STAGES = ($env.FILE_PWD | path join "stages.test.json")
}

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

# Run one case: report it, and leave nothing behind either way.
export def run-case [name: string, body: closure] {
    # Every case gets a sandbox, and it is reaped whether the case passes or
    # fails. Teardown as the last statement of a case is skipped by a failing
    # assertion, so a suite leaks precisely when it is being used most: this
    # box was holding 42 live tmux servers, 40 dead sockets and 67 MB of git
    # worktrees from one afternoon of red runs. `guarded` fixes that one case
    # at a time and only where someone remembered; this fixes the class.
    let sandbox = ([$nu.temp-dir $"piw-case-(random chars --length 8)"] | path join)
    mkdir $sandbox
    # `XDG_STATE_HOME` is sandboxed HERE, for every case, rather than per-suite
    # via something like `with-runtime`: sp029 T6 put the worker placement
    # record (identity, `accepted`/`stopped`) under `$XDG_STATE_HOME`, and a
    # case that forgot to sandbox it would write into this machine's real
    # `~/.local/state/pi-worker` — worse, SILENTLY, since most cases never
    # assert anything about that directory directly. Measured directly: a
    # fixture cwd shared by many cases (`$nu.temp-dir`, used where the actual
    # path does not matter) resolves to the same durable project bucket for
    # all of them, so uids like "a" or "impl-a" accumulated identity envelopes
    # ACROSS cases and across whole suite runs before this existed. A case
    # that needs the true unset-XDG_STATE_HOME fallback overrides this back
    # out with its own `with-env`.
    let state_home = ($sandbox | path join "state")
    let outcome = (try {
        with-env {PIW_CASE_TMP: $sandbox, XDG_STATE_HOME: $state_home} { do $body }
        null
    } catch {|e| $e })
    reap-sandbox $sandbox
    if $outcome == null { return {name: $name, status: "pass", detail: ""} }
    let e = $outcome
    {name: $name, status: "FAIL", detail: (case-detail $e)}
}

# Where a fixture belongs: this case's sandbox when there is one, the temp dir
# otherwise, so a helper called outside a case still works.
export def fixture-base []: nothing -> string {
    $env | get -o PIW_CASE_TMP | default $nu.temp-dir
}

# Mint a private tmux socket name AND record it, so the harness can kill the
# server even when the case that made it died mid-assertion. A socket lives in
# /tmp/tmux-<uid>/ rather than in the sandbox, so the name has to be written
# down for it to be findable.
export def new-tmux-socket [tag: string]: nothing -> string {
    let socket = $"piw-($tag)-(random chars --length 6)"
    let registry = ((fixture-base) | path join ".tmux-sockets")
    $"($socket)\n" | save --append --raw $registry
    $socket
}

# Kill anything the case registered, then remove the sandbox. Never throws:
# reaping runs on the failure path, and an error here would replace the case's
# own diagnosis with a cleanup error.
def reap-sandbox [sandbox: string] {
    let registry = ($sandbox | path join ".tmux-sockets")
    if ($registry | path exists) {
        for socket in (try { open $registry | lines } catch { [] }) {
            let name = ($socket | str trim)
            if ($name | is-not-empty) { do { drop-tmux-server $name } | ignore }
        }
    }
    do { rm -rf $sandbox } | ignore
}

# The detail a failing case reports.
#
# A failing case has to say WHY. Nushell renders an external-command failure as
# the bare string "External command failed", which names neither the command nor
# its stderr — useless in a suite that shells out to git and tmux. When the
# message is that unhelpful, fall back to the structured error record.
#
# Must never throw: it runs on the failure path, and an error while reporting a
# failure would hide the case it was reporting on.
def case-detail [e: any]: nothing -> string {
    let msg = (try { $e.msg } catch { "" })
    if ($msg | str contains "External command failed") {
        let extra = (try { $e | to nuon | str substring 0..500 } catch { "" })
        $"($msg) | ($extra)"
    } else if ($msg | is-empty) {
        (try { $e | to nuon | str substring 0..500 } catch { "unreportable failure" })
    } else {
        $msg
    }
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

# The package directory as install.sh will resolve it: the MAIN worktree.
#
# install.sh deliberately anchors to the main worktree so the path it records
# in Pi's settings survives a feature worktree being removed. A test that
# predicts that path from its OWN location therefore disagrees with it in
# every worktree — which is why two install cases failed deterministically
# there and passed on main, and why "the two known install failures" became
# background noise for a whole session.
#
# So this asks git rather than guessing: both sides now read the same source
# of truth instead of one predicting the other.
export def main-package-dir []: nothing -> string {
    let listed = (do { ^git worktree list --porcelain } | complete)
    let root = (if $listed.exit_code == 0 {
        # First non-bare entry, matching install.sh's awk. Blocks are separated
        # by a blank line and the output ends with one, so empties are dropped
        # before anything reads their first line.
        let candidates = (
            $listed.stdout
            | split row "\n\n"
            | where {|b| ($b | str trim | is-not-empty) }
            | where {|b| not ($b | lines | any {|l| ($l | str trim) == "bare" }) }
            | each {|b| $b | lines | where {|l| $l | str starts-with "worktree " } | get 0? | default "" }
            | each {|w| $w | str replace "worktree " "" | str trim }
            | where {|w| $w | is-not-empty }
        )
        if ($candidates | is-empty) { "" } else { $candidates | first }
    } else { "" })
    let base = (if ($root | is-empty) {
        (do { ^git rev-parse --show-toplevel } | complete | get stdout | str trim)
    } else { $root })
    $base | path join "claude" "marketplace" "plugins" "pi-workers"
}

export def worker-script [caller_dir: string]: nothing -> string {
    repo-root $caller_dir
    | path join "claude" "marketplace" "plugins" "pi-workers" "scripts" "pi-worker.nu"
}

export def pi-extension [caller_dir: string]: nothing -> string {
    repo-root $caller_dir
    | path join "claude" "marketplace" "plugins" "pi-workers" "extensions" "pi.ts"
}

# ------------------------------------------------------------- envelopes

# A minimal well-formed v2 envelope of each kind. Cases mutate one field at a
# time so a rejection is attributable to that field and nothing else.
#
# `content` and `payload` carry the same value on purpose, mirroring the
# bridge `envelope-for` builds in the v1 pipeline (sp029 T2): `result`/
# `error`/`identity` are still validated off `.payload`, `inbox` off
# `.content`, and a sample usable against either dispatch path needs both
# names present.
export def sample-envelope [kind: string]: nothing -> record {
    let base = {
        protocol: 2
        sequence: 1
        run: "run-42"
        uid: "impl-dotfiles-963w.1-a1"
        kind: $kind
        from: "impl-dotfiles-963w.1-a1"
        to: ["run-42"]
        created: "2026-09-05T10:00:00Z"
    }
    let payload = match $kind {
        "inbox" => "do the thing"
        "result" => {
            status: "complete"
            summary: "protocol module landed"
            validation: "PASS"
            window: "impl-dotfiles-963w.1@dotfiles"
            session: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
            resume: "pi --session 0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        }
        "error" => {code: "protocol_error", detail: "agent settled without calling the result tool"}
        "identity" => {
            role: "impl", cwd: "/tmp/nowhere", branch: "wk-t.0"
            session: "sid-a", skill: "wk-build", window: "impl-a@dotfiles"
        }
        _ => {}
    }
    $base | insert content $payload | insert payload $payload
}

# --------------------------------------------------------- bus sandboxes

# Every bus suite runs against its own XDG_RUNTIME_DIR. The bus keys entirely
# off that variable, so an isolated one gives each case a private universe —
# no shared state between cases, and nothing written near the real runtime dir
# of a live session.
export def make-runtime [tag: string]: nothing -> string {
    let root = ([(fixture-base) $"pi-worker-test-($tag)-(random chars --length 6)"] | path join)
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
    let root = ([(fixture-base) $"pi-worker-repo-($tag)-(random chars --length 6)"] | path join)
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

# Run `body`, then `cleanup`, even when the body fails.
#
# This exists because the obvious shape is wrong in a way that only shows up
# later: putting teardown as the last statement of a case means a FAILING
# assertion skips it. The pi-bridge suite was written that way and leaked a
# live tmux server per failed case — 21 of them survived a single afternoon,
# each holding a process and a socket. A test suite that leaks on the failure
# path leaks precisely when it is being used most.
export def guarded [body: closure, cleanup: closure] {
    let outcome = (try { do $body; null } catch {|e| $e })
    do $cleanup
    if $outcome != null { error make {msg: $outcome.msg} }
}

# Tear down a private tmux server AND its socket file.
#
# `kill-server` stops the process but leaves the socket inode behind, so a
# suite that only kills accumulates one dead socket per case — 32 per full run
# here, which is how /tmp/tmux-*/ ends up with hundreds of them. Cleaning both
# is what makes "run the suite twice and compare" a meaningful check.
export def drop-tmux-server [socket: string] {
    do { ^tmux -L $socket kill-server } | complete | ignore
    let path = ([($env | get -o TMUX_TMPDIR | default "/tmp") $"tmux-(^id -u | str trim)" $socket] | path join)
    rm -f $path
}
