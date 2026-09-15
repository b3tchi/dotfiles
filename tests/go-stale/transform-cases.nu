#!/usr/bin/env nu
# Pure transform-layer cases for go-stale (dotfiles-xwg0).
#
# classify-module takes a probe record and decides fresh/stale/missing/
# no-sources with no I/O — every case here is a synthetic record, no disk
# touched, no real files needed.

use harness.nu *
use ../../nushell/actions/go-stale classify-module

let old = ("2026-01-01T00:00:00+00:00" | into datetime)
let new = ("2026-01-02T00:00:00+00:00" | into datetime)

let cases = [
    (run-case "classify/fresh-artifact-newer-than-source" {
        let p = {
            key: "widget"
            artifact_path: "/repo/widget/widget"
            artifact_exists: true
            artifact_mtime: $new
            newest_source: {path: "/repo/widget/main.go", mtime: $old}
            source_count: 1
        }
        let r = (classify-module $p)
        assert-eq $r.status "FRESH"
    })

    (run-case "classify/stale-source-newer-than-artifact" {
        let p = {
            key: "widget"
            artifact_path: "/repo/widget/widget"
            artifact_exists: true
            artifact_mtime: $old
            newest_source: {path: "/repo/widget/main.go", mtime: $new}
            source_count: 1
        }
        let r = (classify-module $p)
        assert-eq $r.status "STALE"
        assert-str-contains $r.reason "main.go" "stale reason must name the newer source file"
        assert-str-contains $r.reason "widget" "stale reason must name the artifact"
    })

    (run-case "classify/missing-artifact-reported-not-crashed" {
        let p = {
            key: "widget"
            artifact_path: "/repo/widget/widget"
            artifact_exists: false
            artifact_mtime: null
            newest_source: {path: "/repo/widget/main.go", mtime: $old}
            source_count: 1
        }
        let r = (classify-module $p)
        assert-eq $r.status "MISSING"
        assert-str-contains $r.reason "widget" ""
    })

    (run-case "classify/no-sources-flags-manifest-bug-ahead-of-artifact-state" {
        let p = {
            key: "widget"
            artifact_path: "/repo/widget/widget"
            artifact_exists: true
            artifact_mtime: $new
            newest_source: null
            source_count: 0
        }
        let r = (classify-module $p)
        assert-eq $r.status "NO_SOURCES"
    })

    (run-case "classify/equal-mtime-is-fresh-not-stale" {
        let p = {
            key: "widget"
            artifact_path: "/repo/widget/widget"
            artifact_exists: true
            artifact_mtime: $new
            newest_source: {path: "/repo/widget/main.go", mtime: $new}
            source_count: 1
        }
        let r = (classify-module $p)
        assert-eq $r.status "FRESH"
    })
]

$cases | to json
