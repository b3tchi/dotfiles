#!/usr/bin/env nu
# Cases for the probe layer of agent-census (ft012 / sp026 Task 3).
#
# The probe layer is the part that shells out, so these cases replace the real
# `claude` / `tmux` / `ps` with stubs on a temporary PATH. That is the only way
# to arrange the failure modes that matter — a broken account, a tmux server
# that is not running, an auth prompt where JSON was expected — deterministically.
#
# Emits results as JSON on stdout; run-tests.nu invokes it as a subprocess.

use ../../nushell/actions/agent-census *

def assert-eq [actual, expected, msg: string = ""] {
    if $actual != $expected {
        error make {msg: $"expected ($expected | to nuon), got ($actual | to nuon). ($msg)"}
    }
}
def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $"assertion failed: ($msg)"} }
}
def run-case [name: string, body: closure] {
    try { do $body; {name: $name, status: "pass", detail: ""} } catch {|e| {name: $name, status: "FAIL", detail: $e.msg} }
}

# Build a throwaway tree of stub executables and fake account dirs.
def make-sandbox [tag: string]: nothing -> string {
    let root = ([$nu.temp-dir $"agent-census-probe-($tag)"] | path join)
    rm -rf $root
    mkdir ($root | path join "bin")
    $root
}

def write-stub [root: string, name: string, body: string] {
    let p = ([$root "bin" $name] | path join)
    $"#!/bin/bash\n($body)\n" | save -f $p
    chmod +x $p
}

# Run a closure with ONLY the sandbox bin on PATH, so a probe that reaches for
# the real claude/tmux/ps finds the stub or nothing at all.
#
# Deliberately does NOT add nushell's own directory: nu lives in /usr/sbin on
# this system, which also holds tmux and ps, so including it would quietly
# hand the probes the real binaries and make the "tmux is absent" case pass
# for the wrong reason. nu is already running; it does not need to be on PATH.
def with-stub-path [root: string, body: closure] {
    with-env {PATH: [([$root "bin"] | path join)]} { do $body }
}

let results = [
    # ---- account discovery ----------------------------------------------
    (run-case "probe/discover-accounts dedupes a symlinked config dir" {
        # ~/.claude is commonly a symlink to one of the suffixed account dirs
        # (it is on this machine). Probing both would double-count every agent
        # in that account.
        let s = (make-sandbox "accounts")
        mkdir ($s | path join ".claude-personal")
        mkdir ($s | path join ".claude-work")
        ln -s ($s | path join ".claude-work") ($s | path join ".claude")
        let found = (discover-accounts --home $s)
        assert-eq ($found | length) 2 "the symlink must not add a third account"
        assert-eq ($found | get name | sort) [personal work]
    })

    (run-case "probe/discover-accounts skips non-directories" {
        let s = (make-sandbox "accountfiles")
        mkdir ($s | path join ".claude-personal")
        "not a dir" | save -f ($s | path join ".claude-backup.tar")
        let found = (discover-accounts --home $s)
        assert-eq ($found | get name) [personal] "a file matching the glob must be skipped"
    })

    (run-case "probe/discover-accounts finds nothing when there is nothing" {
        let s = (make-sandbox "noaccounts")
        assert-eq (discover-accounts --home $s) []
    })

    # ---- agent probe: degradation ---------------------------------------
    (run-case "probe/one broken account does not abort the others" {
        let s = (make-sandbox "brokenacct")
        mkdir ($s | path join ".claude-personal")
        mkdir ($s | path join ".claude-work")
        # Fail loudly for one account, succeed for the other.
        write-stub $s "claude" 'if [[ "$CLAUDE_CONFIG_DIR" == *work ]]; then echo "auth required" >&2; exit 1; fi
echo "[{\"kind\":\"background\",\"state\":\"done\",\"cwd\":\"/home/dev/.dotfiles\",\"sessionId\":\"s1\"}]"'
        let rows = (with-stub-path $s { collect-agents (discover-accounts --home $s) })
        assert-eq ($rows | length) 1 "the healthy account must still contribute"
        assert-eq ($rows | first | get account) "personal"
    })

    (run-case "probe/non-JSON output yields no rows instead of crashing" {
        # A version mismatch or an auth prompt prints prose on stdout with a
        # zero exit. Parsing that must not take the census down.
        let s = (make-sandbox "notjson")
        mkdir ($s | path join ".claude-personal")
        write-stub $s "claude" $': > "($s)/ran"; echo "Please run claude login to continue."'
        let rows = (with-stub-path $s { collect-agents (discover-accounts --home $s) })
        assert-eq $rows []
        # Without this the case passes vacuously: [] is also what a stub that
        # never executed returns.
        assert-true (($s | path join "ran") | path exists) "the stub must actually have been invoked"
    })

    (run-case "probe/zero agents is an empty list, not an error" {
        let s = (make-sandbox "zeroagents")
        mkdir ($s | path join ".claude-personal")
        write-stub $s "claude" $': > "($s)/ran"; echo "[]"'
        assert-eq (with-stub-path $s { collect-agents (discover-accounts --home $s) }) []
        assert-true (($s | path join "ran") | path exists) "the stub must actually have been invoked"
    })

    (run-case "probe/rows are tagged with the account they came from" {
        let s = (make-sandbox "tagging")
        mkdir ($s | path join ".claude-personal")
        mkdir ($s | path join ".claude-work")
        write-stub $s "claude" 'n="${CLAUDE_CONFIG_DIR##*/}"
echo "[{\"kind\":\"background\",\"state\":\"done\",\"cwd\":\"/x/$n\",\"sessionId\":\"$n\"}]"'
        let rows = (with-stub-path $s { collect-agents (discover-accounts --home $s) })
        assert-eq ($rows | get account | sort) [personal work] "each row carries its own account"
    })

    # ---- concurrency -----------------------------------------------------
    (run-case "probe/accounts are probed concurrently, not serially" {
        # Measured, not read off the source: a par-each that silently
        # serialises passes code review and fails this.
        let s = (make-sandbox "timing")
        mkdir ($s | path join ".claude-personal")
        mkdir ($s | path join ".claude-work")
        write-stub $s "claude" '/bin/sleep 0.5; echo "[]"'
        let accounts = (discover-accounts --home $s)
        assert-eq ($accounts | length) 2 "need two accounts for the timing claim to mean anything"
        let t0 = (date now)
        with-stub-path $s { collect-agents $accounts }
        let elapsed = ((date now) - $t0)
        # Serial would be >= 1s. Allow generous headroom for process spawn.
        assert-true ($elapsed < 800ms) $"two 500ms probes took ($elapsed) — that is serial"
    })

    # ---- tmux + ps + registry -------------------------------------------
    (run-case "probe/no tmux server yields an empty pane index" {
        let s = (make-sandbox "notmux")
        write-stub $s "tmux" 'echo "no server running on /tmp/tmux-1000/default" >&2; exit 1'
        assert-eq (with-stub-path $s { probe-panes }) {}
    })

    (run-case "probe/tmux absent entirely yields an empty pane index" {
        # Not the same as a failing tmux: the binary is not on PATH at all.
        let s = (make-sandbox "tmuxgone")
        assert-eq (with-stub-path $s { probe-panes }) {}
    })

    (run-case "probe/pane probe requests session_name as a third field" {
        # Task 2's build-pane-index needs the session NAME to label an
        # ungrouped session. A two-field probe silently loses those panes.
        let s = (make-sandbox "panefields")
        write-stub $s "tmux" 'echo "$@" > /dev/stderr; echo "4598 proj-bravo proj-bravo_0"
echo "99003  scratch_3"'
        let idx = (with-stub-path $s { probe-panes })
        assert-eq ($idx | get "4598") "proj-bravo"
        assert-eq ($idx | get "99003") "scratch" "ungrouped pane must be labelled from the session name"
    })

    (run-case "probe/ps failure yields an empty table" {
        let s = (make-sandbox "nops")
        write-stub $s "ps" 'exit 1'
        assert-eq (with-stub-path $s { probe-ps }) []
    })

    (run-case "probe/missing registry yields an empty record" {
        let s = (make-sandbox "noregistry")
        assert-eq (probe-registry ($s | path join "does-not-exist.yaml")) {}
    })

    (run-case "probe/registry without a projects key yields an empty record" {
        let s = (make-sandbox "emptyregistry")
        let f = ($s | path join "projects.yaml")
        "other: {}\n" | save -f $f
        assert-eq (probe-registry $f) {}
    })

    (run-case "probe/registry is read when present" {
        let s = (make-sandbox "goodregistry")
        let f = ($s | path join "projects.yaml")
        "projects:\n  alpha:\n    path: /tmp/alpha\n" | save -f $f
        assert-eq (probe-registry $f) {alpha: {path: "/tmp/alpha"}}
    })
]

$results | to json
