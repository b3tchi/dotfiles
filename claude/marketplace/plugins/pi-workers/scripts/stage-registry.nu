#!/usr/bin/env nu
# stage-registry — what a worker stage is allowed to do, declared by whoever
# uses the bus (dotfiles-lz7s.1).
#
# The bus is a transport: it starts an agent in a tmux window, carries messages
# to it over a file bus, and takes one typed result back. It used to also carry
# three tables of one particular consumer's vocabulary — that consumer's stage
# names, its placement split, its completion rules — which welded the two
# together and made the transport unusable by anything else.
#
# Those tables are policy, not transport. They live here, supplied by the
# consumer, in vocabulary that describes MECHANISM rather than meaning:
#
#   isolation  "worktree"  the stage gets its own throwaway worktree + branch
#              "main"      the stage runs in the repo's main worktree, shared
#   payload    "ticket"    its message may carry only a stage and a ticket id
#              "instructions"  its message may carry prose and artifact ids
# The bus enforces what this says and never interprets what the names mean.
#
# Deliberately absent: anything about whether a result is GOOD. The bus carries
# a worker's report; judging it is the consumer's job, on receipt. A transport
# that also graded its cargo would need to understand it.

const ISOLATIONS = ["worktree" "main"]
const PAYLOADS = ["ticket" "instructions"]

# Where the registry lives, unless a caller names a file directly.
#
# `PI_WORKER_STAGES` first so a consumer can point at its own file and every
# call agrees, and so tests never touch a real installation.
export def stage-registry-path []: nothing -> string {
    let from_env = ($env | get -o PI_WORKER_STAGES | default "")
    if ($from_env | is-not-empty) { return $from_env }
    let base = ($env | get -o XDG_CONFIG_HOME | default ($env.HOME? | default "" | path join ".config"))
    $base | path join "pi-workers" "stages.json"
}

def check-stage [entry: record, seen: list<string>] {
    let fields = ($entry | columns)

    if ("name" not-in $fields) or (($entry.name? | default "" | is-empty)) {
        error make {msg: $"stage registry entry has no name: ($entry | to json -r). A nameless stage cannot be spawned or gated"}
    }
    let name = $entry.name

    # Duplicates are refused rather than last-wins: two entries claiming one
    # name means the gate that actually applies is a file-order accident.
    if $name in $seen {
        error make {msg: $"stage registry declares '($name)' more than once; which gate applies would be a file-order accident"}
    }

    let isolation = ($entry | get -o isolation | default "")
    if $isolation not-in $ISOLATIONS {
        error make {msg: $"stage '($name)' has isolation '($isolation)': not one of ($ISOLATIONS | str join ', '). A typo must not fall through to the shared tree"}
    }

    let payload = ($entry | get -o payload | default "")
    if $payload not-in $PAYLOADS {
        error make {msg: $"stage '($name)' has payload '($payload)': not one of ($PAYLOADS | str join ', ')"}
    }
}

# Every stage the consumer has declared.
#
# An ABSENT registry is an error, not an empty one. "No stages configured, so
# allow anything" would silently drop every gate the consumer meant to impose —
# the failure mode a registry exists to prevent.
export def load-stages [--path: string = ""]: nothing -> list<record> {
    let file = (if ($path | is-empty) { stage-registry-path } else { $path })
    if not ($file | path exists) {
        error make {msg: $"no stage registry at ($file). The bus enforces stages a consumer declares; install one there or set PI_WORKER_STAGES"}
    }

    let parsed = (try { open --raw $file | from json } catch {
        error make {msg: $"stage registry ($file) is not valid JSON"}
    })
    let stages = ($parsed | get -o stages | default null)
    let shape = ($stages | describe)
    if not (($shape | str starts-with "list") or ($shape | str starts-with "table")) {
        error make {msg: $"stage registry ($file) must be an object with a 'stages' list, got ($shape)"}
    }

    mut seen = []
    for entry in $stages {
        check-stage $entry $seen
        $seen = ($seen | append $entry.name)
    }
    $stages
}

# One stage's rules, or a refusal naming what IS registered.
#
# Listing the known stages matters: an unrecognised name is nearly always a
# typo or a consumer whose registry was not installed, and both are answered by
# seeing the real list.
export def stage-for [name: string, --path: string = ""]: nothing -> record {
    let stages = (load-stages --path $path)
    let row = ($stages | where name == $name)
    if ($row | is-empty) {
        error make {msg: $"unknown stage '($name)': not one of ($stages | get name | str join ', '). A worker with no contract to follow is not launched"}
    }
    $row | first
}
