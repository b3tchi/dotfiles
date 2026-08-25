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

# ---------------------------------------------------- fast-probe fixtures
#
# The fast probe reads an account's state files, so its cases build a real
# account directory rather than stubbing a binary.
#
# Liveness is the one thing that cannot come from a fixture: it is a comparison
# against /proc. These cases therefore borrow the TEST PROCESS's own pid and
# its real start time — nu is certainly running, so a session file written with
# those two values is live by construction on any machine, and one written with
# a deliberately wrong procStart is the pid-reuse case.
def live-pid []: nothing -> int { $nu.pid }

def live-proc-start []: nothing -> string {
    parse-proc-start (open --raw $"/proc/($nu.pid)/stat")
}

def make-account [tag: string]: nothing -> record {
    let root = (make-probe-sandbox $tag)
    let acct = ($root | path join ".claude-fixture")
    mkdir ($acct | path join "sessions")
    mkdir ($acct | path join "jobs")
    {name: "fixture", path: $acct}
}

def write-session [acct: record, name: string, rec: record] {
    $rec | to json | save -f ($acct.path | path join "sessions" $"($name).json")
}

def write-job [acct: record, id: string, rec: record] {
    mkdir ($acct.path | path join "jobs" $id)
    $rec | to json | save -f ($acct.path | path join "jobs" $id "state.json")
}

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

    # ---- fast probe: state files instead of the CLI ----------------------
    (run-case "probe/fast reads a live interactive session" {
        let a = (make-account "fastlive")
        write-session $a "s1" {
            pid: (live-pid), procStart: (live-proc-start), kind: "interactive",
            sessionId: "sid-1", cwd: "/home/dev/alpha", name: "alpha-1", status: "busy",
        }
        let rows = (probe-agents-fast $a)
        assert-eq ($rows | length) 1
        let r = ($rows | first)
        assert-eq $r.kind "interactive"
        assert-eq $r.status "busy"
        assert-eq $r.cwd "/home/dev/alpha"
        assert-eq $r.account "fixture" "the account label must be attached, as probe-agents does"
    })

    (run-case "probe/fast drops a session whose pid was REUSED" {
        # The pid is alive, but it belongs to a different process now. A
        # liveness check on the pid alone would report this stale file as a
        # running agent -- which is exactly the miscount procStart exists to
        # prevent.
        let a = (make-account "fastreuse")
        write-session $a "s1" {
            pid: (live-pid), procStart: "0", kind: "interactive",
            sessionId: "sid-1", cwd: "/home/dev/alpha", name: "alpha-1", status: "busy",
        }
        assert-eq (probe-agents-fast $a) []
    })

    (run-case "probe/fast drops a session whose pid is gone" {
        let a = (make-account "fastdead")
        write-session $a "s1" {
            pid: 2147483646, procStart: "123", kind: "interactive",
            sessionId: "sid-1", cwd: "/home/dev/alpha", name: "alpha-1", status: "idle",
        }
        assert-eq (probe-agents-fast $a) []
    })

    (run-case "probe/fast joins a live bg session to its job record" {
        # The two axes come from two files: `state` is durable and lives in
        # jobs/, `status` exists only while the process does and lives in
        # sessions/. A background agent needs both -- state=blocked with
        # status=idle is the BLOCKED ON YOU row us022 exists to surface.
        let a = (make-account "fastbg")
        write-job $a "job1" {
            state: "blocked", name: "bg one", cwd: "/home/dev/alpha",
            sessionId: "sid-bg", createdAt: 111,
        }
        write-session $a "s1" {
            pid: (live-pid), procStart: (live-proc-start), kind: "bg",
            sessionId: "sid-bg", jobId: "job1", cwd: "/home/dev/alpha",
            name: "bg one", status: "idle",
        }
        let rows = (probe-agents-fast $a)
        assert-eq ($rows | length) 1 "the job and its session are ONE agent, not two"
        let r = ($rows | first)
        assert-eq $r.kind "background"
        assert-eq $r.state "blocked"
        assert-eq $r.status "idle"
        assert-eq (bucket-state $r) "blocked" "the job axis must win over status=idle"
    })

    (run-case "probe/fast keeps a finished job with no live session" {
        let a = (make-account "fastdonejob")
        write-job $a "job1" {
            state: "done", name: "bg one", cwd: "/home/dev/alpha",
            sessionId: "sid-bg", createdAt: 111,
        }
        let r = (probe-agents-fast $a | first)
        assert-eq $r.state "done"
        assert-eq $r.status null "no process means no status -- that is what live-agents filters on"
        assert-eq (live-agents [$r]) [] "a terminal job with no process is not a live agent"
    })

    (run-case "probe/fast reports a job stuck at `working` with no process as failed" {
        # The state file cannot record its own crash: whatever was going to
        # write the terminal state is precisely what stopped running. The CLI
        # derives `failed` here, and the fast path must agree or the two
        # probes disagree about a project's bucket counts.
        let a = (make-account "fastcrash")
        write-job $a "job1" {
            state: "working", name: "bg one", cwd: "/home/dev/alpha",
            sessionId: "sid-bg", createdAt: 111,
        }
        assert-eq (probe-agents-fast $a | first | get state) "failed"
    })

    (run-case "probe/fast leaves a process-less `blocked` job blocked" {
        # The negative control for the case above: a remap of every
        # process-less job would erase the blocked rows, which are the ones
        # worth surfacing.
        let a = (make-account "fastblocked")
        write-job $a "job1" {
            state: "blocked", name: "bg one", cwd: "/home/dev/alpha",
            sessionId: "sid-bg", createdAt: 111,
        }
        assert-eq (probe-agents-fast $a | first | get state) "blocked"
    })

    (run-case "probe/fast survives an unparseable session file" {
        let a = (make-account "fastjunk")
        "{ not json" | save -f ($a.path | path join "sessions" "broken.json")
        write-session $a "s1" {
            pid: (live-pid), procStart: (live-proc-start), kind: "interactive",
            sessionId: "sid-1", cwd: "/home/dev/alpha", name: "alpha-1", status: "idle",
        }
        assert-eq (probe-agents-fast $a | length) 1 "one bad file must not lose the good ones"
    })

    (run-case "probe/fast yields nothing for an account with no state dirs" {
        let root = (make-probe-sandbox "fastbare")
        let acct = ($root | path join ".claude-bare")
        mkdir $acct
        assert-eq (probe-agents-fast {name: "bare", path: $acct}) []
    })

    (run-case "probe/parse-proc-start survives a comm containing spaces and parens" {
        # /proc/<pid>/stat cannot be split on whitespace: field 2 is the
        # executable name, parenthesised, and free to contain both.
        # Fields 1 and 2 are pid and comm; splitting past comm lands on field
        # 3 (state), so starttime -- field 22 -- sits 19 places further on.
        let comm = "(my (odd) proc)"
        let filler = (4..21 | each {|i| $"f($i)" } | str join " ")
        assert-eq (parse-proc-start $"4242 ($comm) S ($filler) 998877") "998877"
    })

    (run-case "probe/parse-proc-start returns null for a truncated line" {
        assert-eq (parse-proc-start "4242 (nu) S 1 2 3") null
    })

    # ---- fast/CLI parity, against the LIVE machine -----------------------
    (run-case "probe/fast agrees with the CLI on this machine" {
        # The one case here that is deliberately NOT hermetic, and the reason
        # the fast path is allowed to exist at all. It reads an INTERNAL
        # layout that nothing upstream promises; this case is what turns a
        # reshaped layout into a red suite instead of a bar badge that has
        # quietly gone blank.
        #
        # Compared as a SET: both probes feed the same `sort-by project
        # account`, and rows tying on both keys come out in probe order, which
        # differs between the two by construction. That ordering is not a
        # promise the census makes.
        #
        # PENDING, never FAIL, when the CLI cannot answer: a box with no
        # `claude` on PATH and no accounts is not evidence of a broken probe.
        let accounts = (discover-accounts)
        if ($accounts | is-empty) {
            return   # nothing to compare; the case passes vacuously by design
        }
        let slow = (collect-agents $accounts)
        if ($slow | is-empty) {
            return   # CLI unavailable or logged out -- see above
        }
        let fast = (collect-agents $accounts --fast)

        def key [rows: list]: nothing -> list {
            $rows | each {|r|
                [($r | get -o sessionId), ($r | get -o kind), ($r | get -o state),
                 ($r | get -o status), ($r | get -o cwd)] | to nuon
            } | sort
        }
        assert-eq (key $fast) (key $slow) "the fast probe must see exactly what the CLI reports"
    })

    (run-case "probe/registry is read when present" {
        let s = (make-probe-sandbox "goodregistry")
        let f = ($s | path join "projects.yaml")
        "projects:\n  alpha:\n    path: /tmp/alpha\n" | save -f $f
        assert-eq (probe-registry $f) {alpha: {path: "/tmp/alpha"}}
    })
]

$results | to json
