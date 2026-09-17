#!/usr/bin/env nu
#
# One-off repair: recover the labels of addresses released BEFORE the
# `dotfiles-mqse` tombstone shipped, so a log that outlived its senders can
# name them again.
#
# `release-address-at` now appends a tombstone to `<state>/<slug>/retired.jsonl`
# before deleting an address record, and `bus-messages` resolves live -> retired
# -> raw. That fix is FORWARD-ONLY by construction: an address released before
# it left no record anywhere, so every envelope those parties sent renders as a
# raw `a01…` for the rest of the bus's life.
#
# The bus can still answer for most of them, because a worker reporting a
# result writes its OWN window into the state envelope:
#
#     {"status":"complete", …, "window":"peer-reminder-v2@dotfiles", …}
#
# That is the worker's own evidence about itself, which is the only kind
# [[adr0017]] lets drive an automatic recovery — so this script mines exactly
# that field and nothing else. It will NOT infer a name from who an address
# talked to, from tmux, or from a bd note: an address whose own envelopes never
# carried a window stays raw, because a guessed name in a log is worse than an
# honest address.
#
# Writes display-only state. `to-address`, `label-address`, `addresses-named`
# and `presence-dir` stay live-only, so a recovered name can never route mail
# or resurrect a claim — the same invariant `dotfiles-mqse` pinned.
#
# Usage:
#   nu scripts/backfill-labels.nu              # plan only, writes nothing
#   nu scripts/backfill-labels.nu --apply      # append the tombstones

def state-root []: nothing -> string {
    let base = ($env | get -o XDG_STATE_HOME | default "")
    if ($base | is-not-empty) {
        return ($base | path join "pi-worker")
    }
    $env.HOME | path join ".local/state/pi-worker"
}

# The project dir under the state root, matched by suffix rather than
# recomputed: the slug is a hash this script has no business re-deriving, and
# getting it wrong would write a tombstone file nothing ever reads.
def project-state-dir [repo: string]: nothing -> string {
    let leaf = ($repo | path basename)
    let root = (state-root)
    # `-a`, because a repo whose own directory starts with a dot (`.dotfiles`)
    # gets a state dir that starts with one too, and a bare `ls` hides it.
    let hits = (ls -a $root | where type == dir | get name | where {|d| ($d | path basename) starts-with $"($leaf)-" })
    if ($hits | length) == 0 {
        error make {msg: $"no pi-worker state dir under ($root) for ($repo)"}
    }
    if ($hits | length) > 1 {
        error make {msg: $"($hits | length) state dirs match ($leaf): ($hits | str join ', ')"}
    }
    $hits | first
}

# Every address that already resolves — live record or existing tombstone.
# Both are skipped: a live label is authoritative and re-tombstoning it would
# be a lie about the party being gone, and an existing tombstone already wins.
def resolved-addresses [dir: string]: nothing -> list<string> {
    let addr_dir = ($dir | path join "addresses")
    let live = (if ($addr_dir | path exists) {
        ls $addr_dir | where type == dir | get name | each {|p| $p | path basename }
    } else { [] })

    let retired_file = ($dir | path join "retired.jsonl")
    let retired = (if ($retired_file | path exists) {
        open $retired_file | lines | where {|l| ($l | str trim | is-not-empty) } | each {|l| $l | from json | get address }
    } else { [] })

    $live | append $retired | uniq
}

# The worker's own window, as it wrote it: "peer-reminder-v2@dotfiles" -> the
# part before the `@`, which is the label the address was claimed under.
def window-label [content: any]: nothing -> string {
    let text = (if ($content | describe) == "string" { $content } else { $content | to json --raw })
    let hit = ($text | parse --regex '"window"\s*:\s*"(?<name>[^"@]+)@' | get -o name.0 | default "")
    $hit | str trim
}

def main [--apply] {
    let repo = (pwd)
    let dir = (project-state-dir $repo)
    let known = (resolved-addresses $dir)
    let msgs = (pi-worker messages --json | from json)

    # Only a party's OWN envelopes are evidence about it, so this walks `from`
    # and never `to`.
    let found = (
        $msgs
        | where {|m| ($m.from | str starts-with "a0") and ($m.from not-in $known) }
        | each {|m| {address: $m.from, name: (window-label $m.content)} }
        | where {|r| $r.name | is-not-empty }
        | uniq-by address
    )

    let unresolved = (
        $msgs
        | each {|m| $m.from | append ($m.to | default []) } | flatten
        | where {|a| ($a | str starts-with "a0") and ($a not-in $known) }
        | uniq
    )
    let unknown = ($unresolved | where {|a| $a not-in ($found | get address) })

    print $"state dir: ($dir)"
    print $"unresolved addresses on the bus: ($unresolved | length)"
    print $"recoverable from their own state envelopes: ($found | length)"
    for r in $found { print $"  ($r.address) -> ($r.name)" }
    if ($unknown | length) > 0 {
        print $"left raw \(no window in their own envelopes\): ($unknown | length)"
        for a in $unknown { print $"  ($a)" }
    }

    if not $apply {
        print ""
        print "plan only — nothing written. Re-run with --apply to append the tombstones."
        return
    }
    if ($found | length) == 0 {
        print ""
        print "nothing to write."
        return
    }

    let path = ($dir | path join "retired.jsonl")
    let existed = ($path | path exists)
    let stamp = (date now | format date "%Y-%m-%dT%H:%M:%S%.6fZ")
    for r in $found {
        # `role` and `kind` are "worker" because only a worker reports a result
        # carrying a window — a run's address never does, so this script cannot
        # mislabel one as the other.
        let line = ({
            address: $r.address
            name: $r.name
            role: "worker"
            project: $repo
            kind: "worker"
            retired_at: $stamp
            recovered_from: "state-envelope-window"
        } | to json --raw)
        $"($line)\n" | save --append $path
    }
    if not $existed { chmod 600 $path }
    print ""
    print $"wrote ($found | length) tombstones to ($path)"
}
