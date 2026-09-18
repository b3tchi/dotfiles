#!/usr/bin/env nu
# Shared harness for the land-bd-task.sh cases (dotfiles-v8fw / dotfiles-luzj).
#
# Same shape as tests/go-stale/harness.nu: tiny asserts, a throwaway sandbox
# per case, and `run-case` returning a record so the runner can print one line
# per case and exit nonzero on any failure.

export def assert-eq [actual, expected, msg: string = ""] {
    if $actual != $expected {
        error make {msg: $"($msg) expected ($expected | to nuon), got ($actual | to nuon)"}
    }
}

export def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $msg} }
}

export def assert-str-contains [haystack: string, needle: string, msg: string = ""] {
    if not ($haystack | str contains $needle) {
        error make {msg: $"($msg) expected to find ($needle | to nuon) in ($haystack | to nuon)"}
    }
}

export def assert-str-excludes [haystack: string, needle: string, msg: string = ""] {
    if ($haystack | str contains $needle) {
        error make {msg: $"($msg) did NOT expect ($needle | to nuon) in ($haystack | to nuon)"}
    }
}

export def run-case [name: string, body: closure] {
    let r = (try { do $body; {status: "pass", detail: ""} } catch {|e| {status: "FAIL", detail: ($e.msg | str substring 0..600)} })
    {name: $name, status: $r.status, detail: $r.detail}
}

# A throwaway git repo with an initial commit on `main`. No remote, so the
# script's `origin/HEAD` lookup falls through to the local branch — the same
# path a fresh clone-less sandbox takes.
export def make-repo [tag: string]: nothing -> string {
    let root = (mktemp -d -t $"land-($tag)-XXXXXX")
    git -C $root init -q -b main
    git -C $root config user.email "test@example.invalid"
    git -C $root config user.name "land test"
    "seed\n" | save -f ($root | path join "README.md")
    git -C $root add README.md
    git -C $root commit -q -m "seed"
    $root
}

# Commit `files` (a list of {path, content}) onto a fresh branch bd-<id>.<iter>
# and return to main, so the script has something to merge.
export def make-branch [root: string, id: string, iter: string, files: list<record>] {
    git -C $root checkout -q -b $"bd-($id).($iter)"
    for f in $files {
        let full = ($root | path join $f.path)
        mkdir ($full | path dirname)
        $f.content | save -f $full
        git -C $root add $f.path
    }
    git -C $root commit -q -m $"work on bd-($id)"
    git -C $root checkout -q main
}

# A stub `bd` plus optional stub tools on PATH.
#
# `bd show <id> --json` answers with `status`, so the script's prior-status
# probe has something to read; `bd update ...` appends its whole argv to
# bd-calls.log so a case can assert on what the script tried to do. Nothing
# here talks to a real beads database — these cases must not touch the
# operator's board.
export def make-stubs [root: string, bd_status: string]: nothing -> string {
    let bin = ($root | path join ".stub-bin")
    mkdir $bin

    let bd = ($bin | path join "bd")
    $"#!/usr/bin/env bash
if [ \"$1\" = \"show\" ]; then
  echo '[{\"status\":\"($bd_status)\"}]'
  exit 0
fi
printf '%s\\n' \"$*\" >> \"($root)/bd-calls.log\"
exit 0
" | save -f $bd
    chmod +x $bd

    # `go` records the directory it was invoked from, which is the whole point
    # of dotfiles-v8fw: the bug was never the command, it was the cwd.
    let go = ($bin | path join "go")
    $"#!/usr/bin/env bash
printf '%s\\n' \"$PWD\" >> \"($root)/go-cwd.log\"
exit 0
" | save -f $go
    chmod +x $go

    $bin
}

# A `go` stub that fails, for the rollback paths.
export def make-go-fail [root: string, bin: string] {
    let go = ($bin | path join "go")
    $"#!/usr/bin/env bash
printf '%s\\n' \"$PWD\" >> \"($root)/go-cwd.log\"
echo 'go: no modules specified' >&2
exit 1
" | save -f $go
    chmod +x $go
}

export def script-path []: nothing -> string {
    $env.FILE_PWD
    | path join "../../claude/marketplace/plugins/infinifu/skills/work-merge/scripts/land-bd-task.sh"
    | path expand
}

# Run the script with the stub bin first on PATH. `LAND_SKIP_GO_REBUILD=1`
# keeps go-stale out of it — these cases are about dep sync and status, and
# the sandbox has no nushell action to rebuild.
export def run-land [root: string, bin: string, id: string, iter: string, test_cmd: string = ""]: nothing -> record {
    # PATH is a LIST in nushell, so the stub dir is PREPENDED to it rather
    # than interpolated into a string — the latter yields a single bogus entry
    # and even `bash` stops resolving.
    with-env {PATH: ([$bin] ++ $env.PATH), LAND_SKIP_GO_REBUILD: "1"} {
        do { ^bash (script-path) $id $iter $root $test_cmd } | complete
    }
}

export def read-log [root: string, name: string]: nothing -> list<string> {
    let p = ($root | path join $name)
    if ($p | path exists) { open $p | lines | where {|l| $l | is-not-empty } } else { [] }
}
