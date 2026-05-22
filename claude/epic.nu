#!/usr/bin/env nu
# epic — manage brainstorm epics (bd epic + idea file + claude session)
# Installed as `epic` via rotz symlink: ~/.local/bin/epic → claude/epic.nu
# Usage:
#   epic create <name>   — create or resume; execs claude in current pane
#   epic delete <name>   — remove bd epic + idea file
#   epic list            — show all epics
#   epic init            — prepare repo (bd hooks, board/* dirs)
#   epic archive create  — snapshot + prune old closed issues
#   epic archive apply   — apply prune-list on other machines

def project_root [] {
    mut cur = $env.PWD
    loop {
        if ($"($cur)/board" | path exists) or ($"($cur)/.beads" | path exists) {
            return $cur
        }
        let parent = ($cur | path dirname)
        if $parent == $cur {
            error make { msg: "Not inside a project (no board/ or .beads/ found walking up from PWD)" }
        }
        $cur = $parent
    }
}

def idea_dir [] {
    let dir = $"(project_root)/board/idea"
    if not ($dir | path exists) {
        error make { msg: $"($dir) not found — run from a project with board/idea/" }
    }
    $dir
}

def archive_dir [] {
    let dir = $"(project_root)/board/archive"
    mkdir $dir
    $dir
}

# Ensures the project has everything wired up for epic workflows:
#   - bd CLI present
#   - .beads/ initialized
#   - bd git hooks installed (idempotent)
#   - board/idea/ and board/archive/ directories exist
# Prints only on action or error; silent when already in good shape.
def preflight [] {
    if (which bd | is-empty) {
        error make { msg: "bd (beads) CLI not found on PATH — run infinifu/install.sh" }
    }

    let root = (project_root)
    if not ($"($root)/.beads" | path exists) {
        error make { msg: $"($root)/.beads not found — run 'bd init' from the project root first" }
    }

    let hooks = try {
        do { ^bd hooks list } | complete
    } catch { { exit_code: 1, stdout: "" } }
    let missing = ($hooks.stdout | lines | where { |l| ($l | str contains "✗") or ($l | str contains "not installed") })
    if ($hooks.exit_code != 0) or (not ($missing | is-empty)) {
        print -e "Installing bd git hooks..."
        ^bd hooks install | ignore
    }

    gate_bd_hooks $root

    for stage in ["idea" "spec" "ready" "done" "archive"] {
        mkdir $"($root)/board/($stage)"
    }
}

# Add a worktree-skip guard above bd's BEGIN BEADS INTEGRATION block.
# Why: .git/hooks/ is shared across worktrees, but .beads/ only lives at
# the main worktree. A linked-worktree commit running the bd hook would
# (a) dirty main's working tree with a re-exported jsonl that the
# worktree commit can't carry, and (b) race the jsonl rewrite with sibling
# worktree commits. The gate short-circuits when --git-dir != --git-common-dir
# (canonical "we are in a linked worktree" check). Idempotent: re-running
# after `bd hooks install` is safe — already-gated hooks are left alone.
def gate_bd_hooks [root: string] {
    let hooks_dir = $"($root)/.git/hooks"
    if not ($hooks_dir | path exists) {
        return
    }
    let gate = "# Skip bd hooks entirely when running from a linked worktree.
# Rationale: dolt is shared across worktrees, but .beads/issues.jsonl
# only lives in the main worktree. Re-exporting from a linked worktree
# would dirty main's working tree without including the diff in the
# worktree commit, and concurrent worktree commits would race on the
# jsonl rewrite. bd state is committed from main only.
if [ \"$(git rev-parse --git-dir 2>/dev/null)\" != \"$(git rev-parse --git-common-dir 2>/dev/null)\" ]; then
  exit 0
fi
"
    for hook in [pre-commit post-merge post-checkout pre-push prepare-commit-msg] {
        let f = $"($hooks_dir)/($hook)"
        if not ($f | path exists) { continue }
        let content = (open --raw $f)
        if ($content | str contains "linked worktree") { continue }
        if not ($content | str contains "BEGIN BEADS INTEGRATION") { continue }
        let patched = ($content | str replace "# --- BEGIN BEADS INTEGRATION" $"($gate)\n# --- BEGIN BEADS INTEGRATION")
        $patched | save --force --raw $f
        print -e $"gated ($hook)"
    }
}

def short_id [full_id: string] {
    $full_id | split row "-" | last
}

def frontmatter [content: string] {
    let lines = ($content | lines)
    if ($lines | is-empty) or ($lines | first) != "---" {
        return []
    }
    let rest = ($lines | skip 1)
    let end = ($rest | enumerate | where item == "---" | get -o 0.index)
    if ($end | is-empty) { return [] }
    $rest | take $end
}

def read_field [content: string, key: string] {
    let fm = (frontmatter $content)
    let matches = ($fm | where { |l| $l | str starts-with $"($key):" })
    if ($matches | is-empty) {
        ""
    } else {
        $matches | first | str replace $"($key):" "" | str trim
    }
}

def read_meta [file: string] {
    let content = (open --raw $file)
    {
        session_id: (read_field $content "claude_session_id")
        bd_id: (read_field $content "bd_epic_id")
    }
}

def main [] {
    print "Usage: epic <init|create|delete|list|archive> [args...]"
    print "  create <name>   — create or resume epic; execs claude in current pane"
    print "  delete <name>   — remove bd epic + idea file"
    print "  list            — show all epics"
    print "  init            — prepare repo: install bd hooks, create board/* dirs"
    print "  archive create  — snapshot + prune closed issues older than cutoff"
    print "  archive apply   — apply cumulative prune-list to local bd (for other machines)"
}

def "main init" [] {
    preflight
    print -e "Repo ready: bd hooks installed, board/{idea,spec,ready,done,archive}/ present."
}

def "main create" [
    name: string
    --no-launch              # skip `exec claude`; just create/resume metadata and print resume cmd
    --profile: string = ""   # claude account: personal | work (default: current $CLAUDE_CONFIG_DIR)
] {
    if not ($name =~ '^[a-zA-Z0-9_-]+$') {
        error make { msg: "Name must contain only alphanumeric characters, dashes, and underscores" }
    }

    let profile_dir = match $profile {
        "" => ""
        "personal" => $"($env.HOME)/.claude-personal"
        "work" => $"($env.HOME)/.claude-work"
        _ => { error make { msg: $"--profile must be 'personal' or 'work', got: ($profile)" } }
    }

    preflight

    let dir = (idea_dir)
    cd (project_root)

    let existing = (glob $"($dir)/($name).*.md")

    let meta = if ($existing | is-empty) {
        let full_id = (^bd q $name --type epic --priority 4 | str trim)
        let short = (short_id $full_id)
        let session_id = (random uuid)
        let idea_file = $"($dir)/($name).($short).md"
        let now = (date now | format date "%Y-%m-%d %H:%M")

        [
            "---"
            $"idea: ($name)"
            $"bd_epic_id: ($full_id)"
            $"claude_session_id: ($session_id)"
            $"created_at: ($now)"
            "---"
            ""
        ] | str join "\n" | save -f $idea_file

        print -e $"Created ($idea_file)"
        print -e $"BD epic:  ($full_id)"

        { session_id: $session_id, short: $short, resume: false, idea_file: $idea_file, bd_id: $full_id }
    } else {
        let idea_file = ($existing | first)
        let m = (read_meta $idea_file)
        let short = (short_id $m.bd_id)
        print -e $"Resuming ($idea_file) — ($m.bd_id)"
        { session_id: $m.session_id, short: $short, resume: true, idea_file: $idea_file, bd_id: $m.bd_id }
    }

    let label = $"($name).($meta.short)"

    let env_prefix = if ($profile_dir == "") { "" } else { $"CLAUDE_CONFIG_DIR=($profile_dir) " }

    if $no_launch {
        print -e ""
        print -e $"Label:    ($label)"
        print -e $"Idea:     ($meta.idea_file)"
        print -e $"BD epic:  ($meta.bd_id)"
        if ($profile_dir != "") { print -e $"Profile:  ($profile) → ($profile_dir)" }
        print -e ""
        if $meta.resume {
            print -e $"Resume in a terminal pane:  ($env_prefix)claude --resume ($meta.session_id) -n ($label)"
        } else {
            print -e $"Start in a terminal pane:   ($env_prefix)claude -n ($label) --session-id ($meta.session_id)"
        }
        return
    }

    if ($profile_dir != "") {
        $env.CLAUDE_CONFIG_DIR = $profile_dir
    }

    if $meta.resume {
        exec claude --resume $meta.session_id -n $label
    } else {
        exec claude -n $label --session-id $meta.session_id
    }
}

def "main delete" [
    name: string
    --force  # skip confirmation
] {
    let dir = (idea_dir)
    let existing = (glob $"($dir)/($name).*.md")
    if ($existing | is-empty) {
        error make { msg: $"No idea file matching ($name).*.md" }
    }
    let idea_file = ($existing | first)
    let m = (read_meta $idea_file)

    if not $force {
        print -e $"Will delete:"
        print -e $"  bd epic: ($m.bd_id)"
        print -e $"  file:    ($idea_file)"
        let ans = (input "Proceed? [y/N]: ")
        if ($ans | str downcase) != "y" {
            print -e "Aborted"
            return
        }
    }

    ^bd delete $m.bd_id --force
    rm $idea_file
    print -e $"Deleted ($m.bd_id) and ($idea_file)"
}

def "main list" [] {
    let board = $"(project_root)/board"
    let stages = ["idea" "spec" "ready" "done"]

    let files = ($stages | each { |stage|
        let d = $"($board)/($stage)"
        if ($d | path exists) {
            let fs = (glob $"($d)/*.md")
            $fs | each { |f| { file: $f, stage: $stage } }
        } else { [] }
    } | flatten)

    if ($files | is-empty) {
        print "No epics"
        return
    }

    let bd_data = try {
        ^bd list --json --type epic --all | from json
    } catch { [] }

    let running = try {
        ^tmux list-panes -a -F '#{pane_title}'
        | lines
        | each { |t| $t | str replace -r '^. ' '' }
        | uniq
    } catch { [] }

    $files | each { |entry|
        let content = (open --raw $entry.file)
        let bd_id = (read_field $content "bd_epic_id")
        if ($bd_id | is-empty) { return null }
        let name = (read_field $content "idea")
        let match = ($bd_data | where id == $bd_id)
        let title = (if ($match | is-empty) { "-" } else { $match | first | get title })
        let bd_status = (if ($match | is-empty) { "-" } else { $match | first | get status })
        let label = (if ($bd_id | is-empty) { "" } else { $"($name).(short_id $bd_id)" })
        let tmux_running = (if ($label != "" and ($label in $running)) { "running" } else { "" })

        {
            name: $name
            bd_id: $bd_id
            title: $title
            bd: $bd_status
            stage: $entry.stage
            tmux: $tmux_running
        }
    }
}

def "main archive create" [
    --before: string  # ISO cutoff date (default: 365 days ago); archive closed issues closed before this
    --yes             # skip confirmation
] {
    cd (project_root)
    let dir = (archive_dir)
    let year = (date now | format date "%Y")
    let snap = $"($dir)/($year).jsonl"
    let prune = $"($dir)/prune-list"

    let cutoff_str = if ($before | is-empty) {
        (date now) - 365day | format date "%Y-%m-%d"
    } else {
        $before
    }

    let closed = try {
        ^bd list --json --status closed --limit 0 | from json
    } catch { [] }

    let to_archive = ($closed | where { |i|
        ($i.closed_at? | default "") != "" and ($i.closed_at < $cutoff_str)
    })

    if ($to_archive | is-empty) {
        print -e $"No closed issues with closed_at < ($cutoff_str) — nothing to archive."
        return
    }

    print -e $"Archiving ($to_archive | length) closed issues \(cutoff: ($cutoff_str)\):"
    $to_archive | select id title closed_at | table | print

    if not $yes {
        let ans = (input "Proceed? [y/N]: ")
        if ($ans | str downcase) != "y" {
            print -e "Aborted"
            return
        }
    }

    ^bd export --all | save -f $snap
    print -e $"Snapshot → ($snap)"

    let new_ids = ($to_archive | get id)
    let existing = if ($prune | path exists) {
        open --raw $prune | lines | where { |l| ($l | str trim) != "" }
    } else { [] }
    let merged = ($existing | append $new_ids | uniq | sort)
    $merged | str join "\n" | save -f $prune
    print -e $"Prune-list → ($prune) \(($merged | length) total IDs\)"

    let tmp = $"/tmp/bd-prune-(random uuid).txt"
    $new_ids | str join "\n" | save -f $tmp
    ^bd delete --from-file $tmp --force | ignore
    rm $tmp
    print -e $"Deleted ($new_ids | length) issues from local bd"

    ^bd export -o .beads/issues.jsonl | ignore
    print -e "Refreshed .beads/issues.jsonl"

    print -e ""
    print -e "Next: review `git status`, commit board/archive/ + .beads/issues.jsonl, push."
}

def "main archive apply" [] {
    let prune = $"(project_root)/board/archive/prune-list"
    if not ($prune | path exists) {
        print -e $"No prune-list at ($prune) — nothing to apply."
        return
    }

    let ids = (open --raw $prune | lines | where { |l| ($l | str trim) != "" })
    if ($ids | is-empty) {
        print -e "Prune-list is empty."
        return
    }

    let before = (try { ^bd list --json --all --limit 0 | from json | length } catch { 0 })
    ^bd delete --from-file $prune --force | ignore
    let after = (try { ^bd list --json --all --limit 0 | from json | length } catch { 0 })
    let deleted = ($before - $after)
    let missing = (($ids | length) - $deleted)
    print -e $"Applied prune-list: deleted ($deleted), already-gone ($missing) of ($ids | length)."
}
