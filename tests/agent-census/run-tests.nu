#!/usr/bin/env nu
# Fixture-driven test runner for agent-census (ft012 / sp026 Task 1).
#
# Runs with NO live agents and NO tmux server: every input comes from
# tests/agent-census/fixtures. That is the point — arranging a real agent into
# `blocked` on demand is not repeatable, and a suite that needs it would only
# ever run on one machine.
#
#   nu tests/agent-census/run-tests.nu
#
# Exit status is 0 when every case passes, 1 when any case fails, so this is
# usable as a gate. PENDING cases (Task 2's pure layer, not written yet) are
# reported loudly but do not fail the run.

# The fixtures use this root. It is deliberately NOT $HOME: the registry paths
# and the agent `cwd` values have to line up for attribution to mean anything,
# and they must line up the same way on every machine.
const FIXTURE_ROOT = "/home/dev"

# Task 2 will create this. Until it exists, transform cases report PENDING.
const CENSUS_ACTION = "nushell/actions/agent-census"

def fixtures [] { $env.FILE_PWD | path join "fixtures" }

def load-json [name: string] {
    open --raw (fixtures | path join $name) | from json
}

# Text fixtures carry `#` provenance headers (JSON cannot, see SOURCES.md).
# Strip them and any CR left by a capture that crossed a Windows pipe.
def load-lines [name: string] {
    open --raw (fixtures | path join $name)
    | lines
    | each {|l| $l | str replace --regex '\r$' '' }
    | where {|l| not ($l | str starts-with "#") }
    | where {|l| ($l | str length) > 0 }
}

def assert-eq [actual, expected, msg: string = ""] {
    if $actual != $expected {
        error make {msg: $"expected ($expected | to nuon), got ($actual | to nuon). ($msg)"}
    }
}

def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $"assertion failed: ($msg)"} }
}

def assert-throws [body: closure, msg: string] {
    let threw = (try { do $body; false } catch { true })
    if not $threw { error make {msg: $"expected a failure but none was raised: ($msg)"} }
}

def run-case [name: string, body: closure] {
    try { do $body; {name: $name, status: "pass", detail: ""} } catch {|e| {name: $name, status: "FAIL", detail: $e.msg} }
}

def pending [name: string, why: string] {
    {name: $name, status: "PENDING", detail: $why}
}

# --- fixture-validation helper -------------------------------------------
# Walks a pid to its owning pane using the ps + panes fixtures. This validates
# the FIXTURES, not the product: Task 2 owns the real `resolve-project`, and
# these cases must keep passing whoever writes it. Kept deliberately dumb.
def walk-to-pane [pid: int, ps: table, panes: record] {
    mut cur = $pid
    for _ in 1..10 {
        let row = ($ps | where pid == $cur)
        if ($row | is-empty) { return null }
        let parent = ($row | first | get ppid)
        # pane keys are strings; comparing the int ppid directly never matches.
        let pkey = ($parent | into string)
        if ($pkey in ($panes | columns)) { return ($panes | get $pkey) }
        if $parent <= 1 { return null }
        $cur = $parent
    }
    null
}

def parse-ps [] {
    load-lines "ps.txt"
    | each {|l|
        let f = ($l | split row --regex '\s+' | where {|x| ($x | str length) > 0})
        {pid: ($f.0 | into int), ppid: ($f.1 | into int)}
    }
}

def parse-panes [name: string] {
    load-lines $name
    | reduce --fold {} {|l, acc|
        let f = ($l | split row " ")
        let pid = ($f.0 | str trim)
        let grp = (if ($f | length) > 1 { $f | skip 1 | str join " " | str trim } else { "" })
        # upsert, not insert: a session GROUP lists the same pane once per member
        # session (dotfiles_0..3 all report pane 788390), so pids repeat.
        if ($grp | is-empty) { $acc } else { $acc | upsert $pid $grp }
    }
}

# =========================================================================
print $"(ansi cyan)agent-census fixture suite(ansi reset)  root=($FIXTURE_ROOT)"
print ""

let harness = [
    # These three exist so the suite can prove it has teeth. If assert-eq ever
    # stops detecting a mismatch, every case below becomes decoration.
    (run-case "harness/detects-inequality" {
        assert-throws { assert-eq 1 2 } "assert-eq must reject unequal values"
    })
    (run-case "harness/detects-thrown-error" {
        assert-throws { error make {msg: "boom"} } "run-case must surface a raised error"
    })
    (run-case "harness/passes-on-equal" { assert-eq 1 1 })
    (run-case "harness/assert-true-rejects-false" {
        assert-throws { assert-true false "x" } "assert-true must reject false"
    })
]

let personal = (load-json "agents-personal.json")
let work     = (load-json "agents-work.json")
let ps       = (parse-ps)
let panes    = (parse-panes "panes.txt")
let registry = (open (fixtures | path join "projects.yaml") | get projects)

let fixture_cases = [
    (run-case "fixtures/both-accounts-parse-and-differ" {
        assert-eq ($personal | length) 7 "personal account record count"
        assert-eq ($work | length) 6 "work account record count"
        # Distinct accounts, else the dual-account fan-out case proves nothing.
        let pc = ($personal | get sessionId | sort)
        let wc = ($work | get sessionId | sort)
        assert-true ($pc != $wc) "the two account fixtures must not be the same capture"
    })

    (run-case "fixtures/state-spread-covers-every-bucket" {
        let all = ($personal ++ $work | each {|r| $r | get -o state | default ($r | get -o status) })
        for s in [busy idle blocked failed done] {
            assert-true ($s in $all) $"fixtures must contain at least one '($s)' agent"
        }
    })

    (run-case "fixtures/both-agent-shapes-present" {
        let all = ($personal ++ $work)
        assert-true (($all | where kind == "interactive" | length) > 0) "need interactive records"
        assert-true (($all | where kind == "background"  | length) > 0) "need background records"
        # The shape split that drives attribution: pid present vs absent.
        assert-true (($all | where {|r| ($r | get -o pid) != null} | length) > 0) "need pid-bearing records"
        assert-true (($all | where {|r| ($r | get -o pid) == null} | length) > 0) "need pid-less records"
    })

    (run-case "fixtures/ancestry-resolves-to-a-pane" {
        # The load-bearing property: an agent pid reaches its pane via ppid.
        let resolved = ($personal ++ $work
            | where {|r| ($r | get -o pid) != null}
            | each {|r| walk-to-pane ($r.pid) $ps $panes }
            | where {|p| $p != null})
        assert-true (($resolved | length) >= 3) "at least 3 agents must resolve to a pane"
        assert-true ("dotfiles" in $resolved) "the dotfiles project must be reachable by ancestry"
    })

    (run-case "fixtures/ancestry-dead-end-is-represented" {
        # A pid whose walk hits init with no pane — the fall-through-to-cwd case.
        let dead = ($personal ++ $work
            | where {|r| ($r | get -o pid) != null}
            | where {|r| (walk-to-pane ($r.pid) $ps $panes) == null })
        assert-true (($dead | length) >= 1) "need one pid-bearing agent with no owning pane"
    })

    (run-case "fixtures/registry-has-a-path-collision" {
        # Two names, one path: cwd alone cannot decide, so the census must not guess.
        let paths = ($registry | columns | each {|n| $registry | get $n | get path })
        let dupes = ($paths | uniq --repeated)
        assert-true (($dupes | length) >= 1) "registry must reproduce the two-names-one-path hazard"
    })

    (run-case "fixtures/registry-has-a-prefix-sibling" {
        # portfolio-old must not be swallowed by a raw string-prefix match on portfolio.
        let p = ($registry | get portfolio | get path)
        let old = ($registry | get portfolio-old | get path)
        assert-true ($old | str starts-with $p) "the sibling must share a string prefix"
        assert-true ($old != $p) "but must be a different path"
    })

    (run-case "fixtures/worktree-job-reports-origin-cwd" {
        # A background job running inside .claude/worktrees/<branch> still reports
        # the repo root. This is why cwd matching is sound at all.
        let roots = ($personal | where kind == "background" | get cwd)
        assert-true ($"($FIXTURE_ROOT)/.dotfiles" in $roots) "need a background job reporting the repo root"
        assert-true (($personal ++ $work | get cwd | where {|c| $c =~ '\.claude/worktrees'} | length) == 0) "no record should report a worktree path as cwd"
    })

    (run-case "fixtures/unknown-states-present-in-both-fields" {
        let u = (load-json "agents-unknown-state.json")
        let states = ($u | each {|r| $r | get -o state | default ($r | get -o status) })
        assert-true ("hibernating" in $states) "need an unknown value in `state`"
        assert-true ("compacting" in $states) "need an unknown value in `status`"
    })

    (run-case "fixtures/empty-inputs-are-empty-not-missing" {
        assert-eq (load-json "agents-empty.json") [] "agents-empty must parse to an empty list"
        assert-eq (load-lines "panes-empty.txt") [] "panes-empty must yield no pane lines"
    })

    (run-case "fixtures/ungrouped-session-yields-no-project" {
        # Two shapes of "no group": trailing space, and no second field at all.
        let p = (parse-panes "panes-ungrouped.txt")
        assert-true ("99001" not-in ($p | columns)) "a pid with a blank group must not map to a project"
        assert-true ("99002" not-in ($p | columns)) "a pid with no group field must not map to a project"
        assert-eq ($p | get "4598") "proj-bravo" "a grouped pane in the same file still maps"
    })

    (run-case "fixtures/crlf-does-not-leak-into-project-names" {
        let p = (parse-panes "panes-crlf.txt")
        assert-eq ($p | get "788390") "dotfiles" "a CR must not stay glued to the project name"
    })

    (run-case "fixtures/headers-are-stripped-not-parsed" {
        let raw = (open --raw (fixtures | path join "panes.txt") | lines)
        assert-true (($raw | first | str starts-with "#")) "panes.txt must carry a provenance header"
        assert-true (((load-lines "panes.txt") | where {|l| $l | str starts-with "#"} | length) == 0) "loader must strip headers"
    })

    (run-case "fixtures/carry-no-real-identifiers" {
        # Regression guard. The repo is public; the raw captures held real
        # project names and task descriptions. If a future re-capture lands
        # unsanitised, this goes red before it reaches a commit.
        let leaked = (ls (fixtures)
            | where type == file
            | each {|f|
                let t = (open --raw $f.name)
                ["/home/jan" "b3tchi" "copacks" "asahi" "mindtime" "auctions" "samples-demo"]
                | where {|tok| $t =~ $tok }
                | each {|tok| $"($f.name | path basename): ($tok)" } }
            | flatten)
        assert-eq $leaked [] "fixtures must contain no real project names or home paths"
    })
]

# --- Task 2's pure layer -------------------------------------------------
# Driven as a subprocess so this file still parses when the action is absent:
# `use` resolves at parse time, and a missing module would take the whole
# suite down instead of reporting three pending cases.
let action_path = ($env.FILE_PWD | path dirname | path dirname | path join $CENSUS_ACTION)
let transform_cases = if ($action_path | path exists) {
    let out = (do { ^$nu.current-exe ($env.FILE_PWD | path join "transform-cases.nu") } | complete)
    if $out.exit_code == 0 {
        $out.stdout | from json
    } else {
        [{name: "transform/<suite crashed>", status: "FAIL", detail: ($out.stderr | str substring 0..600)}]
    }
} else {
    [(pending "transform/bucket-state" "Task 2 (dotfiles-ubc4.2) has not written the pure layer yet")
     (pending "transform/resolve-project" "Task 2 (dotfiles-ubc4.2) has not written the pure layer yet")
     (pending "transform/shape-rows" "Task 2 (dotfiles-ubc4.2) has not written the pure layer yet")]
}

let results = ($harness ++ $fixture_cases ++ $transform_cases)

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
let pend   = ($results | where status == "PENDING" | length)

print ""
print $"($passed) passed, ($failed) failed, ($pend) pending"

if $failed > 0 {
    print $"(ansi red)SUITE FAILED(ansi reset)"
    exit 1
}
if $pend > 0 {
    print $"(ansi yellow)note:(ansi reset) ($pend) case\(s\) await Task 2's pure transform layer."
}
exit 0
