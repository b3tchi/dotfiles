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
use harness.nu *

# A probe sandbox: stub bin plus whatever account dirs the case creates.
def make-probe-sandbox [tag: string]: nothing -> string { make-sandbox "probe" $tag }

let results = [
    # ---- account discovery ----------------------------------------------
    (run-case "probe/discover-accounts dedupes a symlinked config dir" {
        # ~/.claude is commonly a symlink to one of the suffixed account dirs
        # (it is on this machine). Probing both would double-count every agent
        # in that account.
        let s = (make-probe-sandbox "accounts")
        mkdir ($s | path join ".claude-personal")
        mkdir ($s | path join ".claude-work")
        ln -s ($s | path join ".claude-work") ($s | path join ".claude")
        let found = (discover-accounts --home $s)
        assert-eq ($found | length) 2 "the symlink must not add a third account"
        assert-eq ($found | get name | sort) [personal work]
    })

    (run-case "probe/discover-accounts skips non-directories" {
        let s = (make-probe-sandbox "accountfiles")
        mkdir ($s | path join ".claude-personal")
        "not a dir" | save -f ($s | path join ".claude-backup.tar")
        let found = (discover-accounts --home $s)
        assert-eq ($found | get name) [personal] "a file matching the glob must be skipped"
    })

    (run-case "probe/discover-accounts finds nothing when there is nothing" {
        let s = (make-probe-sandbox "noaccounts")
        assert-eq (discover-accounts --home $s) []
    })

    # ---- agent probe: degradation ---------------------------------------
    (run-case "probe/one broken account does not abort the others" {
        let s = (make-probe-sandbox "brokenacct")
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
        let s = (make-probe-sandbox "notjson")
        mkdir ($s | path join ".claude-personal")
        write-stub $s "claude" $': > "($s)/ran"; echo "Please run claude login to continue."'
        let rows = (with-stub-path $s { collect-agents (discover-accounts --home $s) })
        assert-eq $rows []
        # Without this the case passes vacuously: [] is also what a stub that
        # never executed returns.
        assert-true (($s | path join "ran") | path exists) "the stub must actually have been invoked"
    })

    (run-case "probe/zero agents is an empty list, not an error" {
        let s = (make-probe-sandbox "zeroagents")
        mkdir ($s | path join ".claude-personal")
        write-stub $s "claude" $': > "($s)/ran"; echo "[]"'
        assert-eq (with-stub-path $s { collect-agents (discover-accounts --home $s) }) []
        assert-true (($s | path join "ran") | path exists) "the stub must actually have been invoked"
    })

    (run-case "probe/rows are tagged with the account they came from" {
        let s = (make-probe-sandbox "tagging")
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
        let s = (make-probe-sandbox "timing")
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
        let s = (make-probe-sandbox "notmux")
        write-stub $s "tmux" 'echo "no server running on /tmp/tmux-1000/default" >&2; exit 1'
        assert-eq (with-stub-path $s { probe-panes }) {}
    })

    (run-case "probe/tmux absent entirely yields an empty pane index" {
        # Not the same as a failing tmux: the binary is not on PATH at all.
        let s = (make-probe-sandbox "tmuxgone")
        assert-eq (with-stub-path $s { probe-panes }) {}
    })

    (run-case "probe/pane probe requests session_name as a third field" {
        # Task 2's build-pane-index needs the session NAME to label an
        # ungrouped session. A two-field probe silently loses those panes.
        let s = (make-probe-sandbox "panefields")
        write-stub $s "tmux" 'echo "$@" > /dev/stderr; echo "4598 proj-bravo proj-bravo_0"
echo "99003  scratch_3"'
        let idx = (with-stub-path $s { probe-panes })
        assert-eq ($idx | get "4598") "proj-bravo"
        assert-eq ($idx | get "99003") "scratch" "ungrouped pane must be labelled from the session name"
    })

    (run-case "probe/ps failure yields an empty table" {
        let s = (make-probe-sandbox "nops")
        write-stub $s "ps" 'exit 1'
        assert-eq (with-stub-path $s { probe-ps }) []
    })

    (run-case "probe/missing registry yields an empty record" {
        let s = (make-probe-sandbox "noregistry")
        assert-eq (probe-registry ($s | path join "does-not-exist.yaml")) {}
    })

    (run-case "probe/registry without a projects key yields an empty record" {
        let s = (make-probe-sandbox "emptyregistry")
        let f = ($s | path join "projects.yaml")
        "other: {}\n" | save -f $f
        assert-eq (probe-registry $f) {}
    })

    (run-case "probe/registry is read when present" {
        let s = (make-probe-sandbox "goodregistry")
        let f = ($s | path join "projects.yaml")
        "projects:\n  alpha:\n    path: /tmp/alpha\n" | save -f $f
        assert-eq (probe-registry $f) {alpha: {path: "/tmp/alpha"}}
    })
]

$results | to json
