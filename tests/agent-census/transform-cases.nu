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
use harness.nu *

let personal = (load-json $env.FILE_PWD "agents-personal.json")
let work     = (load-json $env.FILE_PWD "agents-work.json")
let agents   = ($personal | each {|r| $r | insert account "personal"}) ++ ($work | each {|r| $r | insert account "work"})
let ps       = (parse-ps-table (load-lines $env.FILE_PWD "ps.txt"))
let panes    = (build-pane-index (load-lines $env.FILE_PWD "panes.txt"))
let registry = (open (fixture-dir $env.FILE_PWD | path join "projects.yaml") | get projects)

let results = [
    # ---- bucket-state ---------------------------------------------------
    
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
            | each {|r| (resolve-project {pid: $r.pid, cwd: ""} $panes $ps {} | get project) }
            | where {|p| $p != "unknown"})
        assert-true (($resolved | length) >= 3) "at least 3 agents must resolve to a pane"
        assert-true ("dotfiles" in $resolved) "the dotfiles project must be reachable by ancestry"
    })

    (run-case "fixtures/ancestry-dead-end-is-represented" {
        # A pid whose walk hits init with no pane — the fall-through-to-cwd case.
        let dead = ($personal ++ $work
            | where {|r| ($r | get -o pid) != null}
            | where {|r| ((resolve-project {pid: $r.pid, cwd: ""} $panes $ps {}) | get how) != "pane" })
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
        let u = (load-json $env.FILE_PWD "agents-unknown-state.json")
        let states = ($u | each {|r| $r | get -o state | default ($r | get -o status) })
        assert-true ("hibernating" in $states) "need an unknown value in `state`"
        assert-true ("compacting" in $states) "need an unknown value in `status`"
    })

    (run-case "fixtures/empty-inputs-are-empty-not-missing" {
        assert-eq (load-json $env.FILE_PWD "agents-empty.json") [] "agents-empty must parse to an empty list"
        assert-eq (load-lines $env.FILE_PWD "panes-empty.txt") [] "panes-empty must yield no pane lines"
    })

    (run-case "fixtures/ungrouped-session-yields-no-project" {
        # Two shapes of "no group": trailing space, and no second field at all.
        let p = (build-pane-index (load-lines $env.FILE_PWD "panes-ungrouped.txt"))
        assert-true ("99001" not-in ($p | columns)) "a pid with a blank group must not map to a project"
        assert-true ("99002" not-in ($p | columns)) "a pid with no group field must not map to a project"
        assert-eq ($p | get "4598") "proj-bravo" "a grouped pane in the same file still maps"
    })

    (run-case "fixtures/crlf-does-not-leak-into-project-names" {
        let p = (build-pane-index (load-lines $env.FILE_PWD "panes-crlf.txt"))
        assert-eq ($p | get "788390") "dotfiles" "a CR must not stay glued to the project name"
    })

    (run-case "fixtures/headers-are-stripped-not-parsed" {
        let raw = (open --raw (fixture-dir $env.FILE_PWD | path join "panes.txt") | lines)
        assert-true (($raw | first | str starts-with "#")) "panes.txt must carry a provenance header"
        assert-true (((load-lines $env.FILE_PWD "panes.txt") | where {|l| $l | str starts-with "#"} | length) == 0) "loader must strip headers"
    })

    (run-case "fixtures/carry-no-real-identifiers" {
        # Regression guard. The repo is public; the raw captures held real
        # project names and task descriptions. If a future re-capture lands
        # unsanitised, this goes red before it reaches a commit.
        let leaked = (ls (fixture-dir $env.FILE_PWD)
            | where type == file
            | each {|f|
                let t = (open --raw $f.name)
                ["/home/jan" "b3tchi" "copacks" "asahi" "mindtime" "auctions" "samples-demo"]
                | where {|tok| $t =~ $tok }
                | each {|tok| $"($f.name | path basename): ($tok)" } }
            | flatten)
        assert-eq $leaked [] "fixtures must contain no real project names or home paths"
    })

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
        let p = (build-pane-index (load-lines $env.FILE_PWD "panes-ungrouped.txt"))
        assert-true ("99001" not-in ($p | columns)) "pid with blank group must not map"
        assert-true ("99002" not-in ($p | columns)) "pid with no group field must not map"
        assert-eq ($p | get "4598") "proj-bravo" "a grouped pane in the same file still maps"
    })

    (run-case "transform/build-pane-index falls back to session name when group is empty" {
        # Third field is the session name; an ungrouped session has no group,
        # and `foo_3` -> `foo`. Requires Task 3 to emit session_name.
        let p = (build-pane-index (load-lines $env.FILE_PWD "panes-ungrouped-named.txt"))
        assert-eq ($p | get "99003") "scratch" "ungrouped session name, _N stripped"
        assert-eq ($p | get "99004") "adhoc"   "ungrouped session name with no _N suffix"
        assert-eq ($p | get "4598")  "proj-bravo" "a real group still beats the name"
    })

    (run-case "transform/build-pane-index strips CR from project names" {
        let p = (build-pane-index (load-lines $env.FILE_PWD "panes-crlf.txt"))
        assert-eq ($p | get "788390") "dotfiles"
    })

    (run-case "transform/build-pane-index on no panes yields an empty index" {
        assert-eq (build-pane-index (load-lines $env.FILE_PWD "panes-empty.txt")) {}
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

    # ---- live-agents -----------------------------------------------------
    (run-case "transform/status presence and pid presence agree on every fixture" {
        # The invariant liveness now rests on. If upstream ever emits `status`
        # without a pid (or vice versa), this fails instead of the census
        # silently miscounting.
        for a in $agents {
            let has_status = (($a | get -o status) != null)
            let has_pid = (($a | get -o pid) != null)
            assert-eq $has_status $has_pid $"($a.name): status and pid must appear together"
        }
        assert-eq ($agents | where {|a| ($a | get -o status) != null} | length) 6 "six fixture records have a process"
    })

    (run-case "transform/live-agents keeps only records whose process exists" {
        let live = (live-agents $agents)
        assert-eq ($agents | length) 13 "fixtures carry the full record set"
        assert-eq ($live | length) 5 "process present, and not finished"
    })

    (run-case "transform/live-agents drops a record with no process" {
        # No `status` field at all: a historical job record.
        let historical = {kind: "background", state: "blocked", cwd: "/x", account: "personal"}
        assert-eq (live-agents [$historical]) [] "no status means no process means not running"
        let running = {kind: "background", state: "blocked", status: "idle", cwd: "/x", account: "personal"}
        assert-eq (live-agents [$running] | length) 1 "the same job WITH a process counts"
    })

    (run-case "transform/live-agents drops a finished agent that is still resident" {
        # A background job that has FINISHED stays resident under
        # `claude bg-pty-host`: it has a process and nothing left to do.
        let live = (live-agents $agents)
        assert-eq ($live | where {|a| ($a | get -o state) in ["done" "failed"]}) [] "terminal states must not count as running"
        let resident_done = ($agents | where {|a| ($a | get -o state) == "done" and ($a | get -o status) != null})
        assert-true (($resident_done | length) >= 1) "fixtures must contain a resident done agent for this to mean anything"
    })

    (run-case "transform/live-agents keeps a window-less blocked agent" {
        # THE regression that would gut the feature: us022 exists because
        # blocked background agents are invisible until you walk the sessions.
        let orphan = {pid: 4242, kind: "background", state: "blocked", status: "idle", cwd: "/x", account: "personal"}
        assert-eq (live-agents [$orphan] | length) 1 "a blocked background agent with no pane must still count"
        assert-eq (live-agents [($orphan | update state "working" | update status "busy")] | length) 1 "so must a working one"
    })

    # ---- dedupe-sessions -------------------------------------------------
    (run-case "transform/dedupe-sessions keeps the live twin of a resumed session" {
        # Upstream emits one sessionId twice when a session is resumed: a live
        # record plus a historical leftover. Counting both inflated --all.
        let live = {sessionId: "s1", pid: 42, kind: "interactive", status: "busy", cwd: "/x"}
        let leftover = {sessionId: "s1", kind: "background", state: "done", cwd: "/x"}
        let out = (dedupe-sessions [$leftover $live])
        assert-eq ($out | length) 1 "one session must yield one record"
        assert-eq ($out | first | get status) "busy" "the LIVE twin must win, whichever order they arrive in"
        # ...and the same holds with the arguments the other way round.
        assert-eq (dedupe-sessions [$live $leftover] | first | get status) "busy"
    })

    (run-case "transform/dedupe-sessions never merges two sessions sharing a name" {
        # The near-miss: POC019-021 exists under TWO sessionIds on the real
        # machine. Deduping by name would silently lose a real agent.
        let a = {sessionId: "s1", pid: 1, kind: "background", state: "blocked", status: "idle", cwd: "/x", name: "same name"}
        let b = {sessionId: "s2", pid: 2, kind: "background", state: "blocked", status: "idle", cwd: "/y", name: "same name"}
        assert-eq (dedupe-sessions [$a $b] | length) 2 "distinct sessions must both survive"
    })

    (run-case "transform/dedupe-sessions keeps records that have no sessionId" {
        # Unmatched records cannot be paired up, so none may be dropped.
        let x = {kind: "background", state: "blocked", cwd: "/x"}
        let y = {kind: "background", state: "blocked", cwd: "/y"}
        assert-eq (dedupe-sessions [$x $y] | length) 2
    })

    (run-case "transform/dedupe-sessions leaves already-unique input alone" {
        # The real fixtures contain one duplicated sessionId or none; either
        # way the count must equal the distinct-sessionId count.
        let out = (dedupe-sessions $agents)
        let distinct = ($agents | get sessionId | uniq | length)
        assert-eq ($out | length) $distinct "output must have exactly one record per session"
    })

    # ---- the two axes ----------------------------------------------------
    (run-case "transform/bucket-state reads the job axis, not the process axis" {
        # status=idle + state=blocked is ALIVE AND WAITING ON YOU. Bucketing it
        # as idle from the process axis would bury the row us022 is for.
        assert-eq (bucket-state {kind: "background", state: "blocked", status: "idle"}) "blocked"
        assert-eq (bucket-state {kind: "background", state: "working", status: "busy"}) "working"
        assert-eq (bucket-state {kind: "background", state: "done", status: "idle"}) "done"
    })

    (run-case "transform/bucket-state uses the process axis for interactive agents" {
        # Interactive records carry no job axis at all.
        assert-eq (bucket-state {kind: "interactive", status: "busy"}) "working"
        assert-eq (bucket-state {kind: "interactive", status: "idle"}) "idle"
    })

    (run-case "transform/detail rows surface both axes separately" {
        let rows = (detail-rows $agents $panes $ps $registry)
        let cols = ($rows | first | columns)
        assert-true ("state" in $cols) "the job axis must be its own column"
        assert-true ("status" in $cols) "so must the process axis"
        let resident_done = ($rows | where state == "done" and status == "idle")
        assert-true (($resident_done | length) >= 1) "the idle+done pair must be visible, not merged away"
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

    # ---- pi runtime (sp030 T6) --------------------------------------------

    (run-case "pi/pi-bucket-state maps every one of the nine persisted states" {
        # WORKER_STATES in pi-worker.nu, in full -- each gets its own real
        # bucket, not a fallthrough to `other`.
        assert-eq (pi-bucket-state "created")        "idle"
        assert-eq (pi-bucket-state "running")        "working"
        assert-eq (pi-bucket-state "waiting_human")  "blocked"
        assert-eq (pi-bucket-state "blocked")        "blocked"
        assert-eq (pi-bucket-state "protocol_error") "blocked"
        assert-eq (pi-bucket-state "failed")         "blocked"
        assert-eq (pi-bucket-state "complete")       "done"
        assert-eq (pi-bucket-state "accepted")       "done"
        assert-eq (pi-bucket-state "stopped")        "done"
    })

    (run-case "pi/pi-bucket-state routes an invented state to other, not idle" {
        # The mutation this catches: a `default "idle"` swallowing anything
        # new upstream ships, same as the claude-side guard above.
        assert-eq (pi-bucket-state "hibernating") "other"
        # The bus's own "no identity recorded" sentinel is not a WORKER_STATE
        # either, and must surface the same way rather than being mistaken
        # for a real job state.
        assert-eq (pi-bucket-state "unknown") "other"
    })

    (run-case "pi/parse-pi-window reads role, subject and project off the CLI's own format" {
        let p = (parse-pi-window "probe-audit-sample-task@dotfiles")
        assert-eq $p.role "probe"
        assert-eq $p.project "dotfiles"
        assert-eq $p.subject "audit-sample-task"
    })

    (run-case "pi/parse-pi-window degrades an identity-less worker to all-empty" {
        # main workers reports window: "" for a uid with no identity written
        # yet -- the ordinary shape for a freshly-claimed address.
        assert-eq (parse-pi-window "") {role: "", project: "", subject: ""}
    })

    (run-case "pi/parse-pi-window degrades a malformed window without raising" {
        assert-eq (parse-pi-window "no-at-sign-here") {role: "", project: "", subject: ""}
    })

    (run-case "pi/pi-detail-row carries uid, role and runtime for a pi agent" {
        let w = {
            run: "r9", uid: "impl-7", state: "running", unacked: 0, task: "",
            window: "impl-fix-the-thing@myproj", resume: "pi --session x", presence: "streaming",
        }
        let row = (pi-detail-row $w)
        assert-eq $row.runtime "pi"
        assert-eq $row.uid "impl-7"
        assert-eq $row.role "impl"
        assert-eq $row.project "myproj"
        assert-eq $row.state "running"
        assert-eq $row.status "streaming" "presence is exposed as the status column"
        assert-eq $row.bucket "working"
        # branch is not obtainable from `pi-worker workers` alone -- see the
        # comment on pi-detail-row. Empty, not fabricated.
        assert-eq $row.branch ""
    })

    (run-case "pi/pi-detail-row: a missing presence file buckets from the job axis alone" {
        # Edge case from the task design: status empty, bucket unaffected.
        let w = {run: "r9", uid: "w1", state: "blocked", unacked: 0, task: "", window: "impl-w1@proj", resume: "", presence: ""}
        let row = (pi-detail-row $w)
        assert-eq $row.status ""
        assert-eq $row.bucket "blocked"
    })

    (run-case "pi/pi-detail-row: an identity-less worker lands in unknown, how=unmatched" {
        let w = {run: "r1", uid: "impl-1", state: "unknown", unacked: 0, task: "", window: "", resume: "", presence: ""}
        let row = (pi-detail-row $w)
        assert-eq $row.project "unknown"
        assert-eq $row.how "unmatched"
        assert-eq $row.bucket "other"
    })

    (run-case "pi/detail-rows (claude) now carries the same runtime/uid/role/branch columns, empty" {
        let rows = (detail-rows $agents $panes $ps $registry)
        let r = ($rows | first)
        assert-eq $r.runtime "claude"
        assert-eq $r.uid ""
        assert-eq $r.role ""
        assert-eq $r.branch ""
    })

    (run-case "pi/pi-count-rows folds pi agents into per-project bucket counts" {
        let workers = [
            {run: "r1", uid: "a", state: "running",       window: "impl-a@alpha", presence: ""}
            {run: "r1", uid: "b", state: "waiting_human", window: "impl-b@alpha", presence: ""}
            {run: "r1", uid: "c", state: "complete",      window: "impl-c@beta",  presence: ""}
        ]
        let rows = (pi-count-rows $workers)
        let alpha = ($rows | where project == "alpha" | first)
        assert-eq $alpha.working 1
        assert-eq $alpha.blocked 1
        assert-eq $alpha.total 2
        let beta = ($rows | where project == "beta" | first)
        assert-eq $beta.done 1
        assert-eq $beta.total 1
    })

    (run-case "pi/merge-runtime-counts adds pi counts onto a matching claude project" {
        let claude_rows = [
            {project: "alpha", path: "/x/alpha", idle: 1, working: 0, blocked: 0, done: 0, other: 0, total: 1,
             accounts: {personal: 1, work: 0}, cwds: []}
        ]
        let pi_rows = [{project: "alpha", idle: 0, working: 1, blocked: 0, done: 0, other: 0, total: 1}]
        let merged = (merge-runtime-counts $claude_rows $pi_rows)
        assert-eq ($merged | length) 1 "one project row, combined -- not two"
        let a = ($merged | first)
        assert-eq $a.idle 1
        assert-eq $a.working 1
        assert-eq $a.total 2 "counts from both runtimes add"
        assert-eq $a.path "/x/alpha" "claude's registry path survives the merge"
    })

    (run-case "pi/merge-runtime-counts adds a new row for a pi-only project" {
        let claude_rows = [
            {project: "alpha", path: "/x/alpha", idle: 0, working: 1, blocked: 0, done: 0, other: 0, total: 1,
             accounts: {personal: 1, work: 0}, cwds: []}
        ]
        let pi_rows = [{project: "gamma", idle: 0, working: 0, blocked: 1, done: 0, other: 0, total: 1}]
        let merged = (merge-runtime-counts $claude_rows $pi_rows)
        assert-eq ($merged | length) 2
        let g = ($merged | where project == "gamma" | first)
        assert-eq $g.blocked 1
        assert-eq $g.path null "pi has no registry path of its own"
        assert-eq $g.cwds [] "pi never contributes a cwd"
        assert-eq $g.accounts {personal: 0, work: 0}
    })

    (run-case "pi/merge-runtime-counts returns claude_rows UNCHANGED when there are no pi rows" {
        # The regression guard a claude-only machine depends on: identity, not
        # merely equality, so a claude-only census is byte-for-byte the same
        # census this action always produced.
        let claude_rows = (shape-rows $agents $panes $ps $registry)
        assert-eq (merge-runtime-counts $claude_rows []) $claude_rows
    })

    (run-case "pi/a mixed-runtime project sums both runtimes' counts" {
        let reg = {"mixedproj": {path: "/x/mixedproj"}}
        let claude_rows = (shape-rows [{cwd: "/x/mixedproj", kind: "background", state: "working", status: "busy", account: "personal"}] {} [] $reg)
        let pi_rows = (pi-count-rows [{run: "r1", uid: "w1", state: "blocked", window: "impl-w1@mixedproj", presence: ""}])
        let merged = (merge-runtime-counts $claude_rows $pi_rows)
        assert-eq ($merged | length) 1
        let m = ($merged | first)
        assert-eq $m.working 1 "claude's agent"
        assert-eq $m.blocked 1 "pi's agent"
        assert-eq $m.total 2 "both runtimes counted in one row"
    })

    (run-case "pi/fixture: the captured pi-worker workers payload carries the documented fields" {
        let workers = (load-json $env.FILE_PWD "pi-workers.json")
        assert-true (($workers | length) > 0) "fixture must not be empty"
        for f in [run uid state unacked task window resume presence] {
            assert-true ($f in ($workers | first | columns)) $"fixture row is missing ($f)"
        }
        # Deliberately includes at least one identity-less worker (empty
        # window) and at least one with a parsable window, matching the two
        # shapes pi-detail-row must handle.
        assert-true (($workers | where window == "" | length) > 0) "need at least one identity-less worker"
        assert-true (($workers | where window != "" | length) > 0) "need at least one worker with a window"
    })
]

$results | to json
