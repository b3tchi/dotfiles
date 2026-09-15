# Shared test harness for the go-stale suites (dotfiles-xwg0).
#
# Assertions + case runner + a throwaway sandbox builder live here once.
# Every suite imports them:
#
#   use harness.nu *

export def assert-eq [actual, expected, msg: string = ""] {
    if $actual != $expected {
        error make {msg: $"expected ($expected | to nuon), got ($actual | to nuon). ($msg)"}
    }
}

export def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $"assertion failed: ($msg)"} }
}

export def assert-str-contains [haystack: string, needle: string, msg: string = ""] {
    if not ($haystack | str contains $needle) {
        error make {msg: $"expected `($haystack)` to contain `($needle)`. ($msg)"}
    }
}

export def run-case [name: string, body: closure] {
    try { do $body; {name: $name, status: "pass", detail: ""} } catch {|e| {name: $name, status: "FAIL", detail: $e.msg} }
}

# A throwaway directory under $nu.temp-dir, wiped before use so reruns start
# clean. NOT under the repo — go-stale's own manifest globs the real repo, so
# every sandbox test passes an explicit --repo / repo_root pointing here
# instead.
export def make-sandbox [tag: string] {
    let root = ([$nu.temp-dir $"go-stale-($tag)"] | path join)
    rm -rf $root
    mkdir $root
    $root
}

# Write a file and then force its mtime, so "which file is newer" is
# deterministic instead of racing the filesystem clock between two `save`s
# in the same test.
export def write-timestamped [path: string, content: string, when: string] {
    let dir = ($path | path dirname)
    if not ($dir | path exists) { mkdir $dir }
    $content | save -f $path
    ^touch -d $when $path
}
