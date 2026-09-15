#!/usr/bin/env nu
# Probe-layer cases for go-stale (dotfiles-xwg0) — real files, real mtimes,
# a throwaway sandbox that stands in for the repo. This is the load-bearing
# suite: it proves a module whose SOURCE is newer than its ARTIFACT gets
# reported STALE, against a fixture this suite controls (never against live
# repo state — someone may rebuild akm-graph-d underneath a run).

use harness.nu *
use ../../nushell/actions/go-stale probe-module
use ../../nushell/actions/go-stale classify-module

def widget-module [] {
    {
        key: "widget"
        dot_yaml: "widget/dot.yaml"
        artifact: "widget/widget"
        build_dir: "widget"
        build_pkg: "."
        cgo_disabled: false
        sources: ["widget/*.go"]
    }
}

let cases = [
    # THE load-bearing case: source newer than artifact -> STALE, and named.
    (run-case "probe/stale-when-source-newer-than-artifact" {
        let root = (make-sandbox "probe-stale")
        write-timestamped ($root | path join "widget/widget") "binary-bytes" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "widget/main.go") "package main" "2026-01-02 00:00:00"

        let result = (classify-module (probe-module $root (widget-module)))

        assert-eq $result.status "STALE"
        assert-str-contains $result.reason "main.go" "must name the newer source file"
    })

    (run-case "probe/fresh-when-artifact-newer-than-every-source" {
        let root = (make-sandbox "probe-fresh")
        write-timestamped ($root | path join "widget/main.go") "package main" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "widget/widget") "binary-bytes" "2026-01-02 00:00:00"

        let result = (classify-module (probe-module $root (widget-module)))

        assert-eq $result.status "FRESH"
    })

    (run-case "probe/missing-artifact-reported-without-crashing" {
        let root = (make-sandbox "probe-missing")
        write-timestamped ($root | path join "widget/main.go") "package main" "2026-01-01 00:00:00"
        # no artifact written at all

        let result = (classify-module (probe-module $root (widget-module)))

        assert-eq $result.status "MISSING"
    })

    (run-case "probe/glob-covers-multiple-source-dirs-picks-newest" {
        let root = (make-sandbox "probe-multi")
        let m = {
            key: "widget"
            dot_yaml: "widget/dot.yaml"
            artifact: "widget/widget"
            build_dir: "widget"
            build_pkg: "."
            cgo_disabled: false
            sources: ["widget/*.go" "widget/internal/**/*.go"]
        }
        write-timestamped ($root | path join "widget/widget") "binary-bytes" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "widget/main.go") "package main" "2026-01-01 12:00:00"
        write-timestamped ($root | path join "widget/internal/sub/deep.go") "package sub" "2026-01-03 00:00:00"

        let result = (classify-module (probe-module $root $m))

        assert-eq $result.status "STALE"
        assert-str-contains $result.reason "deep.go" "must pick the newest file across every glob, not just the first"
    })

    (run-case "probe/resolve-artifact-expands-home-relative-target" {
        use ../../nushell/actions/go-stale resolve-artifact
        let resolved = (resolve-artifact "/repo" "~/.local/bin/thing")
        assert-true (not ($resolved | str starts-with "~")) "must expand ~ to an absolute path"
        assert-str-contains $resolved ".local/bin/thing" ""
    })

    (run-case "probe/resolve-artifact-joins-repo-relative-target" {
        use ../../nushell/actions/go-stale resolve-artifact
        let resolved = (resolve-artifact "/repo" "widget/widget")
        assert-eq $resolved "/repo/widget/widget"
    })
]

$cases | to json
