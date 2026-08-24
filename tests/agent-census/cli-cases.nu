#!/usr/bin/env nu
# Cases for the CLI surface of agent-census (ft012 / sp026 Task 4).
#
# These run the ASSEMBLED action end-to-end as a subprocess, with stubbed
# claude/tmux/ps on a bare PATH, so the assertions are about the published
# contract — flags, output shape, exit status — rather than about internals
# the other two suites already cover.

use harness.nu *

const ACTION = "../../nushell/actions/agent-census"

def action-path [] { $env.FILE_PWD | path join $ACTION | path expand }

# A sandbox whose stubs report a known, fixed world:
#   two accounts, five agents, one pane, one registry collision.
def make-world [tag: string]: nothing -> string {
    let root = (make-sandbox "cli" $tag)
    mkdir ($root | path join ".claude-personal")
    mkdir ($root | path join ".claude-work")

    # personal: one interactive with a pid that resolves through the pane,
    # one background in a colliding registry path. work: three background.
    #
    # The payloads go to files and the stub reads them with bash's $(<file)
    # redirection: stub bodies run on a PATH containing only this sandbox, so
    # `cat` is unavailable, and embedding the JSON inline gets brace-expanded
    # by bash once nu's string interpolation has eaten the quoting.
    let personal = '[{"pid":4242,"kind":"interactive","status":"busy","cwd":"/w/alpha","sessionId":"p1","name":"alpha work"},{"pid":4243,"kind":"background","state":"working","cwd":"/w/tied","sessionId":"p2","name":"tied job"}]'
    $personal | save -f ($root | path join "personal.json")
    let work = '[{"pid":4244,"kind":"background","state":"blocked","cwd":"/w/alpha","sessionId":"w1","name":"blocked one"},{"pid":4245,"kind":"background","state":"waiting","cwd":"/w/alpha","sessionId":"w2","name":"failed one"},{"pid":4246,"kind":"background","state":"hibernating","cwd":"/w/beta","sessionId":"w3","name":"odd state"}]'
    $work | save -f ($root | path join "work.json")
    let body = ('if [[ "$CLAUDE_CONFIG_DIR" == *personal ]]; then printf "%s" "$(<' + $root + '/personal.json)"; else printf "%s" "$(<' + $root + '/work.json)"; fi')
    write-stub $root "claude" $body

    write-stub $root "tmux" 'echo "4200 alpha alpha_0"'
    # 4242 hangs off the pane; the rest are live but parentless. All five are
    # RUNNING and none is in a terminal state, so the liveness and
    # terminal-state filters leave this world alone -- those are exercised by
    # make-mixed-world and the dedicated cases below.
    write-stub $root "ps" 'echo "4242 4200"; echo "4243 1"; echo "4244 1"; echo "4245 1"; echo "4246 1"'

    $"projects:\n  alpha:\n    path: /w/alpha\n  beta:\n    path: /w/beta\n  tied:\n    path: /w/tied\n  tied-py:\n    path: /w/tied\n" | save -f ($root | path join "projects.yaml")
    $root
}

# A world shaped like the real machine: one RUNNING agent plus historical job
# records that carry no pid at all, which is what `claude agents --all --json`
# returns for jobs that finished or died long ago.
def make-mixed-world [tag: string]: nothing -> string {
    let root = (make-world $tag)
    let personal = '[{"pid":4242,"kind":"interactive","status":"busy","cwd":"/w/alpha","sessionId":"p1","name":"running"},{"kind":"background","state":"blocked","cwd":"/w/alpha","sessionId":"p2","name":"stale blocked"}]'
    $personal | save -f ($root | path join "personal.json")
    let work = '[{"kind":"background","state":"done","cwd":"/w/beta","sessionId":"w1","name":"stale done"},{"kind":"background","state":"failed","cwd":"/w/beta","sessionId":"w2","name":"stale failed"}]'
    $work | save -f ($root | path join "work.json")
    write-stub $root "ps" 'echo "4242 4200"'
    $root
}

# Invoke the action the way a consumer would: one exec, bare PATH, its own
# HOME so account discovery finds the sandbox rather than the real accounts.
def run-action [root: string, ...args: string]: nothing -> record {
    with-env {
        PATH: [([$root "bin"] | path join)]
        HOME: $root
        PROJECT_CONFIG_PATH: ($root | path join "projects.yaml")
        CLAUDE_CONFIG_DIR: null
    } {
        do --ignore-errors { ^$nu.current-exe (action-path) ...$args } | complete
    }
}

let results = [
    (run-case "cli/bare invocation prints a per-project table" {
        let r = (run-action (make-world "table"))
        assert-eq $r.exit_code 0 "a completing census exits 0"
        assert-true ($r.stdout | str contains "alpha") "the table must name the projects"
        assert-true ($r.stdout | str contains "project") "the table must carry a header"
    })

    (run-case "cli/json-and-table-agree" {
        # Catches a shaping change applied to only one surface.
        let w = (make-world "agree")
        let j = (run-action $w "--json")
        assert-eq $j.exit_code 0
        let rows = ($j.stdout | from json)
        let alpha = ($rows | where project == "alpha" | first)
        # personal busy -> working; work blocked + failed -> blocked
        assert-eq $alpha.working 1
        assert-eq $alpha.blocked 2
        assert-eq $alpha.total 3
        let table = (run-action $w)
        for r in $rows {
            assert-true ($table.stdout | str contains $r.project) $"table is missing ($r.project)"
        }
    })

    (run-case "cli/unknown states survive into the other bucket" {
        let rows = ((run-action (make-world "other") "--json").stdout | from json)
        let beta = ($rows | where project == "beta" | first)
        assert-eq $beta.other 1 "hibernating must be counted, not dropped"
        assert-eq $beta.total 1
    })

    (run-case "cli/ambiguous registry path lands in unknown" {
        let rows = ((run-action (make-world "tied") "--json").stdout | from json)
        let u = ($rows | where project == "unknown")
        assert-eq ($u | length) 1 "the tied/tied-py collision must not be guessed"
        assert-eq ($u | first | get cwds) ["/w/tied"]
    })

    (run-case "cli/detail-rows-sum-to-counts" {
        # Catches a bucketing bug the counts-only view would hide.
        let w = (make-world "detail")
        let counts = ((run-action $w "--json").stdout | from json)
        let detail = ((run-action $w "--json" "--detail").stdout | from json)
        assert-eq ($detail | length) ($counts | get total | math sum) "one detail row per counted agent"
        assert-eq ($detail | length) 5 "the stub world has five agents"
    })

    (run-case "cli/detail carries the documented per-agent fields" {
        let detail = ((run-action (make-world "fields") "--json" "--detail").stdout | from json)
        let cols = ($detail | first | columns | sort)
        for f in [project account kind state bucket name cwd pid] {
            assert-true ($f in $cols) $"detail row is missing ($f)"
        }
        let interactive = ($detail | where kind == "interactive" | first)
        assert-eq $interactive.project "alpha" "the pid-bearing agent resolves through its pane"
        assert-eq $interactive.how "pane"
    })

    (run-case "cli/flags-compose" {
        # --json with --detail must give detail rows AS json, not one winning.
        let out = (run-action (make-world "compose") "--json" "--detail")
        assert-eq $out.exit_code 0
        let rows = ($out.stdout | from json)
        assert-true (($rows | first | columns) | any {|c| $c == "bucket"}) "must be detail rows"
        assert-eq ($rows | length) 5
    })

    (run-case "cli/--project restricts to one row" {
        let out = (run-action (make-world "proj") "--json" "--project" "alpha")
        let rows = ($out.stdout | from json)
        assert-eq ($rows | length) 1
        assert-eq ($rows | first | get project) "alpha"
        assert-eq $out.exit_code 0
    })

    (run-case "cli/--project with no agents is empty and still exits 0" {
        # A registered project with nothing running, and a name that is not
        # registered at all: both are answers, not errors.
        let w = (make-world "emptyproj")
        let registered = (run-action $w "--json" "--project" "gamma")
        assert-eq $registered.exit_code 0 "an agent-free project is not an error"
        assert-eq ($registered.stdout | from json) []
        let unregistered = (run-action $w "--json" "--project" "no-such-project")
        assert-eq $unregistered.exit_code 0 "an unknown project name is not an error either"
        assert-eq ($unregistered.stdout | from json) []
    })

    (run-case "cli/empty-census-exits-zero" {
        let w = (make-world "empty")
        write-stub $w "claude" 'echo "[]"'
        let out = (run-action $w "--json")
        assert-eq $out.exit_code 0 "zero agents is a successful census"
        assert-eq ($out.stdout | from json) [] "and an empty result, not a fabricated zero row"
    })

    (run-case "cli/survives a world with no tmux and no registry" {
        let w = (make-world "degraded")
        rm -f ([$w "bin" "tmux"] | path join)
        rm -f ($w | path join "projects.yaml")
        let out = (run-action $w "--json")
        assert-eq $out.exit_code 0
        let rows = ($out.stdout | from json)
        # Everything unattributable, but nothing lost.
        assert-eq ($rows | get total | math sum) 5
        assert-eq ($rows | get project) ["unknown"]
    })

    (run-case "cli/default counts only running agents" {
        # The stub world's five records: one carries pid 4242, which the ps
        # stub reports. The other four have no pid -- historical job records.
        let rows = ((run-action (make-mixed-world "live") "--json").stdout | from json)
        assert-eq ($rows | get total | math sum) 1 "only the pid-bearing record is running"
        assert-eq ($rows | get project) ["alpha"] "and it belongs to alpha via its pane"
    })

    (run-case "cli/a finished agent with a live process is not counted" {
        # The reported bug: a done background job stays resident under the
        # daemon, so a pid check alone keeps counting it. It has no tmux
        # window and nothing left to do.
        let w = (make-mixed-world "terminal")
        let personal = '[{"pid":4242,"kind":"interactive","status":"busy","cwd":"/w/alpha","sessionId":"p1","name":"running"},{"pid":4243,"kind":"background","state":"done","cwd":"/w/alpha","sessionId":"p2","name":"finished but resident"}]'
        $personal | save -f ($w | path join "personal.json")
        '[]' | save -f ($w | path join "work.json")
        write-stub $w "ps" 'echo "4242 4200"; echo "4243 1"'
        let live = ((run-action $w "--json").stdout | from json | get total | math sum)
        assert-eq $live 1 "the done-but-resident agent must not count"
        let all = ((run-action $w "--json" "--all").stdout | from json | get total | math sum)
        assert-eq $all 2 "--all still shows it"
    })

    (run-case "cli/a window-less blocked agent is still counted" {
        # The regression that would gut the feature: us022 exists because
        # blocked background agents are invisible until you walk the sessions.
        let w = (make-mixed-world "orphanblocked")
        let personal = '[{"pid":4243,"kind":"background","state":"blocked","cwd":"/w/alpha","sessionId":"p1","name":"blocked, no window"}]'
        $personal | save -f ($w | path join "personal.json")
        '[]' | save -f ($w | path join "work.json")
        write-stub $w "ps" 'echo "4243 1"'
        let rows = ((run-action $w "--json").stdout | from json)
        assert-eq ($rows | get total | math sum) 1 "no tmux window must not mean uncounted"
        assert-eq ($rows | first | get blocked) 1
    })

    (run-case "cli/--all restores the historical records" {
        let w = (make-mixed-world "allflag")
        let live = ((run-action $w "--json").stdout | from json | get total | math sum)
        let all = ((run-action $w "--json" "--all").stdout | from json | get total | math sum)
        assert-eq $live 1
        assert-eq $all 4 "--all brings back the three record-only agents"
        assert-true ($all > $live) "the two views must actually differ"
    })

    (run-case "cli/--all composes with --detail" {
        let w = (make-mixed-world "alldetail")
        let d = ((run-action $w "--json" "--detail").stdout | from json)
        let da = ((run-action $w "--json" "--detail" "--all").stdout | from json)
        assert-eq ($d | length) 1
        assert-eq ($da | length) 4
    })

    (run-case "cli/no running agents yields an empty table, exit 0" {
        # Every record historical: nothing is running, which is an answer.
        let w = (make-mixed-world "nolive")
        write-stub $w "ps" 'echo "1 0"'
        let out = (run-action $w "--json")
        assert-eq $out.exit_code 0
        assert-eq ($out.stdout | from json) []
    })

    (run-case "cli/piped output carries no ANSI escapes" {
        # stdout captured by a consumer must not be handed control characters.
        let out = (run-action (make-world "ansi"))
        # \u{1b} rather than `char esc`, which is not a valid char name here.
        assert-true (not ($out.stdout | str contains "\u{1b}")) "piped table must be plain text"
    })

    (run-case "cli/json output is parseable and not pretty-printed into a table" {
        let out = (run-action (make-world "jsonshape") "--json")
        let parsed = (try { $out.stdout | from json } catch { null })
        assert-true ($parsed != null) "stdout must be valid JSON"
        assert-true (($parsed | describe) =~ '^(list|table)') "JSON must decode to rows"
    })
]

$results | to json
