#!/usr/bin/env nu
# epic — bd (beads) housekeeping for AKM-style projects.
# Installed as `epic` via rotz symlink: ~/.local/bin/epic → claude/epic.nu
#
# Subcommands:
#   epic init            — prepare repo (strip bd auto-hooks, pin bd config)
#   epic export          — bd Dolt → .beads/issues-snapshot.jsonl (commit-ready)
#   epic import          — .beads/issues-snapshot.jsonl → bd Dolt (after a git pull)
#   epic archive create  — snapshot + prune old closed issues
#   epic archive apply   — apply prune-list on other machines
#
# Scope:
#   This tool is bd housekeeping ONLY. AKM zettel management (sp### create,
#   delete, list, board.md updates) lives in the `akm` CLI. bd epic / task
#   creation and closure are handled by lifecycle skills (`spec-ready` mints
#   the bd epic + child tasks when sp### → ready; `spec-retro` closes them
#   when sp### → done). Use this CLI for project-level bd state plumbing
#   only: hook stripping, jsonl snapshot/restore, and archival pruning.
#
# State model:
#   - Dolt = source of truth for bd state on this machine.
#   - .beads/issues-snapshot.jsonl = history snapshot committed to git, rewritten only
#     on `epic export` or `epic archive create`. Never written by hooks.
#   - Cross-machine sync = `bd dolt push/pull` (db-to-db) when a Dolt remote
#     is configured. The jsonl-in-git is an out-of-band history record, not
#     a live sync channel — that is what caused the merge-clobber loop.

def project_root [] {
    mut cur = $env.PWD
    loop {
        if ($"($cur)/.beads" | path exists) {
            return $cur
        }
        let parent = ($cur | path dirname)
        if $parent == $cur {
            error make { msg: "Not inside a project (no .beads/ found walking up from PWD)" }
        }
        $cur = $parent
    }
}

def archive_dir [] {
    let dir = $"(project_root)/board/archive"
    mkdir $dir
    $dir
}

# Ensures the project's bd state is wired up for the Dolt-canonical model:
#   - bd CLI present
#   - .beads/ initialized
#   - bd auto-hooks uninstalled (export/import is manual via epic export/import)
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
}

# Pin bd config keys that enforce the Dolt-canonical / manual-export model.
# Defensive — a fresh clone, `bd init` re-run, or future bd version that
# resets defaults would otherwise silently re-enable auto-export and we'd
# be back to the merge-clobber loop. Each `bd config set` is a no-op when
# the value already matches, so this is idempotent and silent on re-runs.
def ensure_bd_config [] {
    let desired = {
        "export.auto":      "false"                     # disable jsonl auto-write
        "export.git-add":   "false"                     # no auto-`git add`
        "export.path":      "issues-snapshot.jsonl"     # off bd's default-import watch path
        "dolt.auto-commit": "on"                        # commit Dolt writes so state persists
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

def main [] {
    print "Usage: epic <init|export|import|archive> [args...]"
    print "  init            — prepare repo: strip bd auto-hooks, pin bd config"
    print "  export          — bd Dolt → .beads/issues-snapshot.jsonl (commit-ready snapshot)"
    print "  import          — .beads/issues-snapshot.jsonl → bd Dolt (after a git pull)"
    print "  archive create  — snapshot + prune closed issues older than cutoff"
    print "  archive apply   — apply cumulative prune-list to local bd (for other machines)"
    print ""
    print "Note: sp### / board.md / lifecycle minting is `akm create` and the lifecycle skills."
}

def "main init" [] {
    preflight
    print -e "Repo ready: bd auto-hooks stripped, bd config pinned."
    print -e "Sync model: bd Dolt = canonical. Use `epic export` to refresh"
    print -e ".beads/issues-snapshot.jsonl before committing, `epic import` after a pull."
}

# Write current Dolt state to .beads/issues-snapshot.jsonl. Run before `git commit`
# when you want the jsonl snapshot to capture a status change.
def "main export" [] {
    cd (project_root)
    ^bd export -o .beads/issues-snapshot.jsonl
    print -e "Exported bd Dolt → .beads/issues-snapshot.jsonl"
}

# Replay .beads/issues-snapshot.jsonl into the local Dolt. Run after `git pull` if you
# want the pulled jsonl (peer history) merged into your Dolt. Skip when you
# trust your local Dolt is more recent than what just arrived — that is the
# whole reason auto-import was removed.
def "main import" [
    --force  # skip confirmation
] {
    cd (project_root)
    let jsonl = ".beads/issues-snapshot.jsonl"
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

    ^bd export -o .beads/issues-snapshot.jsonl | ignore
    print -e "Refreshed .beads/issues-snapshot.jsonl"

    print -e ""
    print -e "Next: review `git status`, commit board/archive/ + .beads/issues-snapshot.jsonl, push."
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
