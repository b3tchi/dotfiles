#!/usr/bin/env nu
# Cases for the pure transform layer of agent-census (ft012 / sp026 Task 2).
#
# Run as a subprocess by run-tests.nu and emits its results as JSON on stdout,
# so a missing or broken action module cannot take the whole suite down at
# parse time. Runnable directly too, which is what you want while developing:
#
#   nu tests/agent-census/transform-cases.nu | from json
#
# Every case here asserts a VALUE. None assert that a function exists or
# returns non-null — that flavour of test passes against a stub and catches
# nothing.

use ../../nushell/actions/agent-census *

const FIXTURE_ROOT = "/home/dev"

def fixtures [] { $env.FILE_PWD | path join "fixtures" }
def load-json [name: string] { open --raw (fixtures | path join $name) | from json }
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
def run-case [name: string, body: closure] {
    try { do $body; {name: $name, status: "pass", detail: ""} } catch {|e| {name: $name, status: "FAIL", detail: $e.msg} }
}

let personal = (load-json "agents-personal.json")
let work     = (load-json "agents-work.json")
let agents   = ($personal | each {|r| $r | insert account "personal"}) ++ ($work | each {|r| $r | insert account "work"})
let ps       = (parse-ps-table (load-lines "ps.txt"))
let panes    = (build-pane-index (load-lines "panes.txt"))
let registry = (open (fixtures | path join "projects.yaml") | get projects)

let results = [
    # ---- bucket-state ---------------------------------------------------
    (run-case "transform/bucket-state maps every documented state" {
        assert-eq (bucket-state {kind: "interactive", status: "busy"})    "working"
        assert-eq (bucket-state {kind: "background",  state:  "working"}) "working"
        assert-eq (bucket-state {kind: "interactive", status: "idle"})    "idle"
        assert-eq (bucket-state {kind: "interactive", status: "shell"})   "idle"
        assert-eq (bucket-state {kind: "interactive", status: "waiting"}) "blocked"
        assert-eq (bucket-state {kind: "background",  state:  "blocked"}) "blocked"
        assert-eq (bucket-state {kind: "background",  state:  "failed"})  "blocked"
        assert-eq (bucket-state {kind: "background",  state:  "done"})    "done"
    })

    (run-case "transform/bucket-state routes unknown states to other, not idle" {
        # The mutation this catches: a `default "idle"` that silently swallows
        # anything new upstream ships.
        assert-eq (bucket-state {kind: "background",  state:  "hibernating"}) "other"
        assert-eq (bucket-state {kind: "interactive", status: "compacting"})  "other"
        assert-eq (bucket-state {kind: "background"})                          "other"
    })

    (run-case "transform/bucket-state reads state OR status, whichever is present" {
        # interactive records carry `status`, background carry `state`.
        assert-eq (bucket-state {kind: "background",  state: "done"}) "done"
        assert-eq (bucket-state {kind: "interactive", status: "idle"}) "idle"
    })

    # ---- build-pane-index ------------------------------------------------
    (run-case "transform/build-pane-index tolerates repeated pane pids" {
        # A session GROUP lists each pane once per member session, so pids
        # repeat with the same group. An `insert`-based index throws here.
        assert-eq ($panes | get "788390") "dotfiles"
        assert-eq ($panes | get "4598") "proj-bravo"
    })

    (run-case "transform/build-pane-index drops ungrouped panes" {
        let p = (build-pane-index (load-lines "panes-ungrouped.txt"))
        assert-true ("99001" not-in ($p | columns)) "pid with blank group must not map"
        assert-true ("99002" not-in ($p | columns)) "pid with no group field must not map"
        assert-eq ($p | get "4598") "proj-bravo" "a grouped pane in the same file still maps"
    })

    (run-case "transform/build-pane-index falls back to session name when group is empty" {
        # Third field is the session name; an ungrouped session has no group,
        # and `foo_3` -> `foo`. Requires Task 3 to emit session_name.
        let p = (build-pane-index (load-lines "panes-ungrouped-named.txt"))
        assert-eq ($p | get "99003") "scratch" "ungrouped session name, _N stripped"
        assert-eq ($p | get "99004") "adhoc"   "ungrouped session name with no _N suffix"
        assert-eq ($p | get "4598")  "proj-bravo" "a real group still beats the name"
    })

    (run-case "transform/build-pane-index strips CR from project names" {
        let p = (build-pane-index (load-lines "panes-crlf.txt"))
        assert-eq ($p | get "788390") "dotfiles"
    })

    (run-case "transform/build-pane-index on no panes yields an empty index" {
        assert-eq (build-pane-index (load-lines "panes-empty.txt")) {}
    })

    # ---- resolve-project -------------------------------------------------
    (run-case "transform/resolve-project prefers the pane over the cwd" {
        # THE discriminating case. Same cwd, two verdicts: with a pane the
        # project comes from tmux, without one it falls to the registry.
        let cwd = $"($FIXTURE_ROOT)/repos/acme/portfolio/solution/proj-bravo"
        let withpane = (resolve-project {pid: 4771, cwd: $cwd} $panes $ps $registry)
        let nopane   = (resolve-project {cwd: $cwd} $panes $ps $registry)
        assert-eq $withpane.project "proj-bravo"
        assert-eq $withpane.how "pane"
        assert-eq $nopane.how "cwd"
    })

    (run-case "transform/resolve-project walks ancestors, not just the parent" {
        # agent pid -> shell pid -> pane. A parent-only lookup fails this.
        let r = (resolve-project {pid: 3290937, cwd: "/nowhere"} $panes $ps $registry)
        assert-eq $r.project "dotfiles"
        assert-eq $r.how "pane"
    })

    (run-case "transform/resolve-project refuses to guess on a colliding path" {
        # proj-delta and proj-delta-py share one path: two names, no winner.
        let r = (resolve-project {cwd: $"($FIXTURE_ROOT)/repos/acme/proj-delta"} $panes $ps $registry)
        assert-eq $r.project "unknown" "must not credit an arbitrary one of the two"
        assert-eq $r.how "ambiguous"
    })

    (run-case "transform/resolve-project matches path components, not string prefixes" {
        # /…/portfolio-old must NOT resolve to `portfolio`. This is the bug a
        # naive `str starts-with` produces.
        let r = (resolve-project {cwd: $"($FIXTURE_ROOT)/repos/acme/portfolio-old"} $panes $ps $registry)
        assert-eq $r.project "portfolio-old"
    })

    (run-case "transform/resolve-project takes the longest registry match" {
        # proj-bravo lives under portfolio; the deeper entry must win.
        let r = (resolve-project {cwd: $"($FIXTURE_ROOT)/repos/acme/portfolio/solution/proj-bravo/src"} $panes $ps $registry)
        assert-eq $r.project "proj-bravo"
    })

    (run-case "transform/resolve-project reports unknown when nothing matches" {
        let r = (resolve-project {cwd: "/var/tmp/elsewhere"} $panes $ps $registry)
        assert-eq $r.project "unknown"
        assert-eq $r.how "unmatched"
    })

    (run-case "transform/resolve-project survives a dead pid and an empty registry" {
        # pid not in the ps table at all -> must fall through, not error.
        let r = (resolve-project {pid: 99999999, cwd: $"($FIXTURE_ROOT)/.dotfiles"} $panes $ps $registry)
        assert-eq $r.project "dotfiles"
        assert-eq $r.how "cwd"
        let e = (resolve-project {cwd: $"($FIXTURE_ROOT)/.dotfiles"} $panes $ps {})
        assert-eq $e.project "unknown"
    })

    (run-case "transform/resolve-project is depth-bounded on a ppid cycle" {
        let cyclic = [{pid: 5001, ppid: 5002} {pid: 5002, ppid: 5001}]
        let r = (resolve-project {pid: 5001, cwd: "/var/tmp/elsewhere"} $panes $cyclic $registry)
        assert-eq $r.project "unknown" "a cycle must terminate, not hang"
    })

    # ---- shape-rows ------------------------------------------------------
    (run-case "transform/shape-rows loses and duplicates no agent" {
        let rows = (shape-rows $agents $panes $ps $registry)
        let counted = ($rows | get total | math sum)
        assert-eq $counted ($agents | length) "row totals must sum to the input length"
    })

    (run-case "transform/shape-rows buckets sum to total on every row" {
        let rows = (shape-rows $agents $panes $ps $registry)
        for r in $rows {
            assert-eq ($r.idle + $r.working + $r.blocked + $r.done + $r.other) $r.total $"row ($r.project)"
        }
    })

    (run-case "transform/shape-rows emits the documented field set" {
        let rows = (shape-rows $agents $panes $ps $registry)
        let cols = ($rows | columns | sort)
        assert-eq $cols ([accounts blocked cwds done idle other path project total working] | sort)
    })

    (run-case "transform/shape-rows splits the account breakdown" {
        let rows = (shape-rows $agents $panes $ps $registry)
        let p = ($rows | get accounts | each {|a| $a.personal} | math sum)
        let w = ($rows | get accounts | each {|a| $a.work} | math sum)
        assert-eq $p 7 "personal account total"
        assert-eq $w 6 "work account total"
    })

    (run-case "transform/shape-rows carries cwds on the unknown row only" {
        let rows = (shape-rows $agents $panes $ps $registry)
        # The real fixtures DO produce an unknown row: the proj-delta job has no
        # pane, and proj-delta / proj-delta-py share one path. If that row ever
        # stops appearing, the ambiguity handling has silently changed.
        let unknown = ($rows | where project == "unknown")
        assert-true (($unknown | length) == 1) "fixtures must yield exactly one unknown row"
        let u = ($unknown | first)
        assert-eq $u.path null "the unknown row has no registry path"
        assert-true (($u.cwds | length) > 0) "the unknown row must show the cwds it could not attribute"
        assert-true ($"($FIXTURE_ROOT)/repos/acme/proj-delta" in $u.cwds) "the colliding path must be visible"
        assert-true (($u.accounts.personal + $u.accounts.work) == $u.total) "unknown row accounts must add up"
        # Attributed rows carry the column too (uniform table) but leave it empty.
        let attributed = ($rows | where project != "unknown" | first)
        assert-eq $attributed.cwds [] "attributed rows carry no cwds"
    })

    (run-case "transform/shape-rows on zero agents yields no rows" {
        # Not a row of zeros — an empty table. A fabricated zero row would make
        # a bar render a project that has nothing running.
        assert-eq (shape-rows [] $panes $ps $registry) []
    })

    (run-case "transform/shape-rows tolerates unicode and spaces in project names" {
        let reg = {"proj ünïcode": {path: "/tmp/ünï code"}}
        let rows = (shape-rows [{cwd: "/tmp/ünï code/deep", kind: "background", state: "done", account: "personal"}] {} [] $reg)
        assert-eq ($rows | first | get project) "proj ünïcode"
    })
]

$results | to json
