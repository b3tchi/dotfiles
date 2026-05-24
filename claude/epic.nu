#!/usr/bin/env nu
# epic — manage brainstorm epics (bd epic + idea file + claude session)
# Installed as `epic` via rotz symlink: ~/.local/bin/epic → claude/epic.nu
# Usage:
#   epic create <name>   — create or resume; execs claude in current pane
#   epic delete <name>   — remove bd epic + idea file
#   epic list            — show all epics
#   epic init            — prepare repo (strip bd auto-hooks, board/* dirs)
#   epic export          — bd Dolt → .beads/issues.jsonl (commit-ready)
#   epic import          — .beads/issues.jsonl → bd Dolt (after a git pull)
#   epic archive create  — snapshot + prune old closed issues
#   epic archive apply   — apply prune-list on other machines
#
# State model:
#   - Dolt = source of truth for bd state on this machine.
#   - .beads/issues.jsonl = history snapshot committed to git, rewritten only
#     on `epic export` or `epic archive create`. Never written by hooks.
#   - Cross-machine sync = `bd dolt push/pull` (db-to-db) when a Dolt remote
#     is configured. The jsonl-in-git is an out-of-band history record, not
#     a live sync channel — that is what caused the merge-clobber loop.

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
#   - bd auto-hooks uninstalled (export/import is manual via epic export/import)
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

    strip_bd_hooks $root
    ensure_bd_config

    for stage in ["idea" "spec" "ready" "done" "archive"] {
        mkdir $"($root)/board/($stage)"
    }
}

# Pin bd config keys that enforce the Dolt-canonical / manual-export model.
# Defensive — a fresh clone, `bd init` re-run, or future bd version that
# resets defaults would otherwise silently re-enable auto-export and we'd
# be back to the merge-clobber loop. Each `bd config set` is a no-op when
# the value already matches, so this is idempotent and silent on re-runs.
def ensure_bd_config [] {
    let desired = {
        "export.auto":      "false"   # new namespaced disable for jsonl auto-write
        "export.git-add":   "false"   # don't auto-`git add` the jsonl
        "dolt.auto-commit": "on"      # commit Dolt writes so state persists
    }
    for kv in ($desired | transpose key value) {
        let current = try {
            (^bd config get $kv.key | complete).stdout | lines | last | str trim
        } catch { "" }
        if $current != $kv.value {
            print -e $"Setting bd config ($kv.key) = ($kv.value) \(was: ($current)\)"
            ^bd config set $kv.key $kv.value | ignore
        }
    }
}

# Remove bd's auto-installed hook shims and the legacy worktree-skip gate.
# Rationale: bd hooks auto-export Dolt → jsonl on every commit and auto-import
# jsonl → Dolt on every merge. With jsonl tracked in git, that turns every
# `git pull` into a state-clobber: a peer machine's older jsonl overwrites
# the local Dolt's freshly-closed status, silently reverting closures. We
# keep state in Dolt (manual `epic export` writes jsonl only when we want a
# history snapshot) and rely on `bd dolt push/pull` for cross-machine sync.
# Idempotent: leaves hook files intact and only removes the BEADS INTEGRATION
# block and the linked-worktree gate that wrapped it.
def strip_bd_hooks [root: string] {
    let hooks_dir = $"($root)/.git/hooks"
    if not ($hooks_dir | path exists) { return }

    # Ask bd to uninstall first — it knows where its shims live across versions.
    # bd hooks list marks installed hooks with `✓` and uninstalled with `✗`;
    # we trigger only when at least one `✓` line is present so re-runs after
    # a clean install are silent.
    try {
        let status = (do { ^bd hooks list } | complete)
        if ($status.exit_code == 0) and ($status.stdout | str contains "✓") {
            print -e "Uninstalling bd auto-hooks (epic export/import is manual)..."
            ^bd hooks uninstall | ignore
        }
    } catch { }

    # Belt-and-suspenders: scrub any leftover markers and the worktree gate
    # from earlier epic init runs. bd hooks uninstall removes its own block;
    # this cleans the linked-worktree guard that used to wrap it.
    for hook in [pre-commit post-merge post-checkout pre-push prepare-commit-msg] {
        let f = $"($hooks_dir)/($hook)"
        if not ($f | path exists) { continue }
        let content = (open --raw $f)
        let cleaned = (
            $content
            | str replace -r '(?s)# Skip bd hooks entirely when running from a linked worktree\..*?^fi\n' ''
            | str replace -r '(?s)# --- BEGIN BEADS INTEGRATION.*?# --- END BEADS INTEGRATION[^\n]*\n' ''
        )
        if $cleaned != $content {
            if (($cleaned | str trim) == "#!/usr/bin/env sh") or (($cleaned | str trim) == "") {
                rm $f
                print -e $"removed empty ($hook)"
            } else {
                $cleaned | save --force --raw $f
                print -e $"scrubbed ($hook)"
            }
        }
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
    print "Usage: epic <init|create|delete|list|export|import|archive> [args...]"
    print "  create <name>   — create or resume epic; execs claude in current pane"
    print "  delete <name>   — remove bd epic + idea file"
    print "  list            — show all epics"
    print "  init            — prepare repo: strip bd auto-hooks, create board/* dirs"
    print "  export          — bd Dolt → .beads/issues.jsonl (commit-ready snapshot)"
    print "  import          — .beads/issues.jsonl → bd Dolt (after a git pull)"
    print "  archive create  — snapshot + prune closed issues older than cutoff"
    print "  archive apply   — apply cumulative prune-list to local bd (for other machines)"
}

def "main init" [] {
    preflight
    print -e "Repo ready: bd auto-hooks stripped, board/{idea,spec,ready,done,archive}/ present."
    print -e "Sync model: bd Dolt = canonical. Use `epic export` to refresh"
    print -e ".beads/issues.jsonl before committing, `epic import` after a pull."
}

# Write current Dolt state to .beads/issues.jsonl. Run before `git commit`
# when you want the jsonl snapshot to capture a status change. Mirrors what
# `epic archive create` does at line 372 — same export path, no prune.
def "main export" [] {
    cd (project_root)
    ^bd export -o .beads/issues.jsonl
    print -e "Exported bd Dolt → .beads/issues.jsonl"
}

# Replay .beads/issues.jsonl into the local Dolt. Run after `git pull` if you
# want the pulled jsonl (peer history) merged into your Dolt. Skip when you
# trust your local Dolt is more recent than what just arrived — that is the
# whole reason auto-import was removed.
def "main import" [
    --force  # skip confirmation
] {
    cd (project_root)
    let jsonl = ".beads/issues.jsonl"
    if not ($jsonl | path exists) {
        error make { msg: $"($jsonl) not found" }
    }
    if not $force {
        print -e $"Will replay ($jsonl) into local bd Dolt."
        print -e "This can resurrect closed issues if the jsonl is older than Dolt."
        let ans = (input "Proceed? [y/N]: ")
        if ($ans | str downcase) != "y" {
            print -e "Aborted"
            return
        }
    }
    ^bd import $jsonl
    print -e $"Imported ($jsonl) → bd Dolt"
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
