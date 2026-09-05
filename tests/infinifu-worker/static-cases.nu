#!/usr/bin/env nu
# Transport-boundary cases (sp028 T1).
#
# tmux hosts and displays workers; it is never the bus. That rule is only worth
# writing down if something enforces it, because the shortcut is genuinely
# tempting — `tmux wait-for` really does block until a worker signals, and
# `send-keys` really does deliver a string. Both put orchestration state
# somewhere that cannot be versioned, sequenced, addressed or replayed, and
# `send-keys` types into whatever now occupies a stale target.
#
# These cases fail the build if a forbidden verb ever appears as code rather
# than as a prohibition.

use harness.nu *

const FORBIDDEN = [
    ["verb", "why"];
    ["send-keys", "types text into whatever now occupies the target pane"]
    ["wait-for", "makes tmux the completion channel instead of the bus"]
    ["display-message", "makes a transient UI string carry orchestration state"]
]

# tmux verbs that ARE legitimate: window and process lifecycle only.
const ALLOWED_TMUX = ["new-window" "list-windows" "kill-window" "list-panes"]

let worker = (worker-script $env.FILE_PWD)
let extension = (pi-extension $env.FILE_PWD)
let skill = (
    repo-root $env.FILE_PWD
    | path join "claude" "marketplace" "plugins" "infinifu" "skills" "plan-scrum-master" "SKILL.md"
)

# A line states a prohibition when it forbids rather than performs. Only such a
# line may name a forbidden verb.
def prohibition? [text: string]: nothing -> bool {
    let l = ($text | str lowercase)
    ["never" "not " "no " "nothing" "must not" "forbidden" "excluded" "does not" "cannot" "nor "]
    | any {|marker| $l | str contains $marker }
}

# Comment prose wraps. "Nothing in this extension may use tmux send-keys," and
# its continuation are one sentence, and judging either half alone reads a
# prohibition as an instruction — the same trap that made a line-level grep
# misread the sp027 skill text. Group consecutive comment lines and judge the
# block; a forbidden verb in real code stands alone in its own block and is
# still caught.
def comment-blocks [path: string, prefix: string]: nothing -> list<string> {
    mut blocks = []
    mut current = []
    for line in (open --raw $path | lines) {
        if ($line | str trim | str starts-with $prefix) {
            $current = ($current | append ($line | str trim | str substring ($prefix | str length).. | str trim))
        } else {
            if ($current | is-not-empty) { $blocks = ($blocks | append ($current | str join " ")) }
            $current = []
            $blocks = ($blocks | append $line)
        }
    }
    if ($current | is-not-empty) { $blocks = ($blocks | append ($current | str join " ")) }
    $blocks
}

def code-lines [path: string, comment_prefix: string]: nothing -> list<string> {
    open --raw $path
    | lines
    | where {|l| ($l | str trim | str length) > 0 }
    | where {|l| not ($l | str trim | str starts-with $comment_prefix) }
}

let cases = [
    (run-case "static/worker-script-exists" {
        assert-true ($worker | path exists) $"protocol module missing at ($worker)"
    })

    # ------------------------------------------- no tmux bus in the module
    (run-case "static/no-forbidden-tmux-verb-in-worker-code" {
        let offenders = (
            code-lines $worker "#"
            | enumerate
            | each {|row|
                $FORBIDDEN | each {|f|
                    if ($row.item | str contains $f.verb) {
                        $"($worker | path basename): ($row.item | str trim) — ($f.verb) ($f.why)"
                    }
                } | compact
            } | flatten
        )
        assert-eq $offenders [] "a forbidden tmux verb appears as executable code"
    })

    (run-case "static/no-forbidden-tmux-verb-in-pi-extension" {
        let offenders = (
            comment-blocks $extension "//"
            | where {|b| $FORBIDDEN | any {|f| $b | str contains $f.verb } }
            | where {|b| not (prohibition? $b) }
        )
        assert-eq $offenders [] "the Pi extension must not use tmux as a message channel"
    })

    (run-case "static/no-pane-option-mailbox" {
        # Pane/window options are per-target key-value storage — a mailbox in
        # everything but name, with no sequence, no addressing and no replay.
        #
        # The line between banned and allowed is what the option DOES, not
        # whether an option is set at all. `remain-on-exit` changes how tmux
        # displays a finished window, which is squarely tmux's job here; a
        # user option like `@worker_state` would be coordination state living
        # somewhere that cannot be replayed after a crash. Anything not on the
        # display allowlist stays banned, so a new option write has to be
        # justified here before it can ship.
        let display_options = ["remain-on-exit"]
        let offenders = (
            code-lines $worker "#"
            | where {|l| $l | str contains "tmux" }
            | where {|l| ($l | str contains "set-option") or ($l | str contains "setw") or ($l | str contains "set-window-option") }
            | where {|l| not ($display_options | any {|o| $l | str contains $o }) }
        )
        assert-eq $offenders [] "tmux options must not be used as a mailbox"
    })

    (run-case "static/user-options-are-never-written" {
        # A tmux user option (`@name`) is the mailbox shape specifically: it
        # exists only to hold arbitrary values on a target.
        let offenders = (
            code-lines $worker "#"
            | where {|l| ($l | str contains "tmux") and ($l | str contains "@") }
        )
        assert-eq $offenders [] "tmux user options are storage, not display"
    })

    # ---------------------------------------- the boundary is written down
    (run-case "static/worker-script-documents-the-transport-boundary" {
        let text = (open --raw $worker | str lowercase)
        assert-true ($text | str contains "not the bus") "the module must state that tmux is not the bus"
        for verb in ($FORBIDDEN | get verb) {
            assert-true ($text | str contains $verb) $"the module must name ($verb) as excluded, so the rule is greppable"
        }
    })

    (run-case "static/skill-documents-the-transport-boundary" {
        let text = (open --raw $skill | str lowercase)
        assert-true ($text | str contains "send-keys") "plan-scrum-master must name send-keys as excluded"
        assert-true ($text | str contains "wait-for") "plan-scrum-master must name wait-for as excluded"
        # The prohibition has to be stated, not merely mentioned.
        let stated = (
            open --raw $skill
            | lines
            | where {|l| ($l | str contains "send-keys") or ($l | str contains "wait-for") }
            | any {|l| prohibition? $l }
        )
        assert-true $stated "the skill must forbid the verbs, not just mention them"
    })

    (run-case "static/legitimate-tmux-verbs-remain-available" {
        # Guard against over-correction: banning tmux outright would make the
        # workers invisible, which is the whole point of ft014.
        let text = (open --raw $worker | str lowercase)
        assert-true ($ALLOWED_TMUX | any {|v| $text | str contains $v }) "window lifecycle verbs must stay documented as allowed"
    })

    # ------------------------------------------------ no copied task bodies
    (run-case "static/work-stage-payload-contract-is-documented" {
        let text = (open --raw $worker)
        assert-true ($text | str contains "bd show") "the module must point work stages at bd show"
    })
]

$cases | to json
