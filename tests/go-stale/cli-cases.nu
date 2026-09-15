#!/usr/bin/env nu
# CLI-surface cases for go-stale (dotfiles-xwg0) — runs the assembled action
# as a subprocess against a throwaway sandbox repo, asserting the published
# contract: exit codes, --modules scoping, and manifest-coverage warnings.
# Rebuild-mode is exercised against a real tiny Go module (via a direct
# import of rebuild-module, same function the CLI's cmd-rebuild calls) so it
# proves an actual `go build` + temp-file-then-mv round trip, guarded on a
# real Go toolchain being on PATH so a Go-less CI box degrades to a no-op
# instead of a false pass.

use harness.nu *
use ../../nushell/actions/go-stale rebuild-module

const ACTION = "../../nushell/actions/go-stale"

def action-path [] { $env.FILE_PWD | path join $ACTION | path expand }

def run-action [args: list<string>] {
    do { ^$nu.current-exe (action-path) ...$args } | complete
}

def widget-repo [tag: string] {
    make-sandbox $"cli-($tag)"
}

let cases = [
    (run-case "cli/check-exits-nonzero-when-a-module-is-stale" {
        let root = (widget-repo "stale")
        write-timestamped ($root | path join "hotkeyd/hotkeyd") "bin" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main" "2026-01-02 00:00:00"

        let out = (run-action ["check" "--repo" $root "--modules" "hotkeyd"])

        assert-eq $out.exit_code 1
        assert-str-contains $out.stdout "STALE" ""
    })

    (run-case "cli/check-exits-zero-when-selected-module-fresh" {
        let root = (widget-repo "fresh")
        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "hotkeyd/hotkeyd") "bin" "2026-01-02 00:00:00"

        let out = (run-action ["check" "--repo" $root "--modules" "hotkeyd"])

        assert-eq $out.exit_code 0
    })

    (run-case "cli/check-is-the-default-subcommand" {
        let root = (widget-repo "default")
        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "hotkeyd/hotkeyd") "bin" "2026-01-02 00:00:00"

        let out = (run-action ["--repo" $root "--modules" "hotkeyd"])

        assert-eq $out.exit_code 0
        assert-str-contains $out.stdout "hotkeyd" "default (no subcommand) run must still report the module"
    })

    (run-case "cli/modules-flag-restricts-report-to-named-keys" {
        let root = (widget-repo "scoped")
        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "hotkeyd/hotkeyd") "bin" "2026-01-02 00:00:00"

        let out = (run-action ["check" "--repo" $root "--modules" "hotkeyd"])

        assert-true (not ($out.stdout | str contains "akm-graph")) "unscoped module must not appear in a --modules-restricted report"
    })

    (run-case "cli/list-prints-every-manifest-entry" {
        let out = (run-action ["list"])
        assert-eq $out.exit_code 0
        for key in ["agent-monitor" "akm-graph" "preview" "hotkeyd" "gopass-secretservice" "gopass-relay" "d2-router"] {
            assert-str-contains $out.stdout $key $"list must include ($key)"
        }
    })

    (run-case "cli/coverage-warning-fires-for-an-unmanifested-go-build" {
        let root = (widget-repo "coverage")
        mkdir ($root | path join "newtool")
        "linux:\n  installs:\n    cmd: go build -o ~/.local/bin/newtool .\n" | save -f ($root | path join "newtool/dot.yaml")
        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "hotkeyd/hotkeyd") "bin" "2026-01-02 00:00:00"

        let out = (run-action ["check" "--repo" $root "--modules" "hotkeyd"])

        assert-str-contains $out.stderr "newtool/dot.yaml" "an un-manifested go-build module must warn by name"
    })

    (run-case "cli/coverage-warning-ignores-worktree-copies-of-dot-yaml" {
        # .worktrees/* are full working-tree copies (work-do's per-task
        # worktrees): every real module's dot.yaml exists there too, at a
        # path no manifest entry lists. Regression for a real false-positive
        # hit against the live repo (dotfiles-xwg0): every module warned on
        # every worktree before this exclusion existed.
        let root = (widget-repo "worktree-noise")
        mkdir ($root | path join ".worktrees/wk-echo.0/newtool")
        "linux:\n  installs:\n    cmd: go build -o ~/.local/bin/newtool .\n" | save -f ($root | path join ".worktrees/wk-echo.0/newtool/dot.yaml")
        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "hotkeyd/hotkeyd") "bin" "2026-01-02 00:00:00"

        let out = (run-action ["check" "--repo" $root "--modules" "hotkeyd"])

        assert-true (not ($out.stderr | str contains "newtool")) "a dot.yaml under .worktrees/ must not trigger a coverage warning"
    })

    (run-case "cli/rebuild-produces-a-fresh-binary-via-real-go-build" {
        if (which go | is-empty) {
            print "  (skipped: no go toolchain on PATH)"
        } else {
            let root = (widget-repo "rebuild")
            let mod_dir = ($root | path join "buildable")
            mkdir $mod_dir
            "module buildable\n\ngo 1.21\n" | save -f ($mod_dir | path join "go.mod")
            write-timestamped ($mod_dir | path join "main.go") "package main\n\nfunc main() {}\n" "2026-01-02 00:00:00"

            let m = {key: "buildable", artifact: "buildable/buildable", build_dir: "buildable", build_pkg: ".", cgo_disabled: false}
            let outcome = (rebuild-module $root $m)

            assert-eq $outcome.status "REBUILT"
            let artifact = ($root | path join "buildable/buildable")
            assert-true ($artifact | path exists) "rebuild must produce the artifact"
        }
    })

    (run-case "cli/verify-flags-a-drifted-manifest-row" {
        # Rejection #1 gap 1: the manifest itself can drift from its
        # dot.yaml (renamed -o target, moved artifact) without any
        # check/rebuild run ever noticing — `verify` is the dedicated,
        # fail-on-drift command for exactly that.
        let root = (widget-repo "verify-drift")
        mkdir ($root | path join "hotkeyd")
        "linux:\n  installs:\n    cmd: |\n      go build -C \"$SRC\" -o \"$TMP\" ./cmd/hotkeyd\n      mv -f \"$TMP\" \"$SRC/hotkeyd-renamed\"\n" | save -f ($root | path join "hotkeyd/dot.yaml")

        let out = (run-action ["verify" "--repo" $root])

        assert-eq $out.exit_code 1
        assert-str-contains $out.stdout "DRIFT" "a drifted row must be reported as DRIFT"
        assert-str-contains $out.stdout "hotkeyd" "must name the drifted module"
    })

    (run-case "cli/verify-passes-against-the-real-repo-dot-yaml-files" {
        let real_repo = ($env.FILE_PWD | path join "../.." | path expand)
        let out = (run-action ["verify" "--repo" $real_repo])
        assert-eq $out.exit_code 0
    })

    (run-case "cli/since-scopes-check-to-modules-the-diff-actually-touched" {
        # This is what work-merge's post-merge gate relies on: --since
        # <ORIG_HEAD> must report only the module(s) the merge changed, not
        # every module the manifest knows about.
        let root = (widget-repo "since-scope")
        mkdir $root
        ^git -C $root init -q -b main
        ^git -C $root config user.email "t@t.example"
        ^git -C $root config user.name "t"

        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "hotkeyd/hotkeyd") "bin" "2026-01-01 01:00:00"
        write-timestamped ($root | path join "agent-monitor/main.go") "package main" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "agent-monitor/agent-monitor") "bin" "2026-01-01 01:00:00"
        ^git -C $root add -A
        ^git -C $root commit -q -m base
        let base_sha = (^git -C $root rev-parse HEAD | str trim)

        # "The merge": only hotkeyd's source changes and goes stale relative
        # to its (untouched, older) artifact. agent-monitor is untouched and
        # stays fresh.
        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main v2" "2026-01-02 00:00:00"
        ^git -C $root add -A
        ^git -C $root commit -q -m touch-hotkeyd

        let out = (run-action ["check" "--repo" $root "--since" $base_sha])

        assert-eq $out.exit_code 1
        assert-str-contains $out.stdout "hotkeyd" "the touched module must appear in a --since-scoped report"
        assert-true (not ($out.stdout | str contains "agent-monitor")) "an untouched module must not appear in a --since-scoped report"
    })

    (run-case "cli/since-with-nothing-touched-is-a-clean-noop" {
        let root = (widget-repo "since-noop")
        mkdir $root
        ^git -C $root init -q -b main
        ^git -C $root config user.email "t@t.example"
        ^git -C $root config user.name "t"
        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main" "2026-01-01 00:00:00"
        ^git -C $root add -A
        ^git -C $root commit -q -m base
        let base_sha = (^git -C $root rev-parse HEAD | str trim)
        # second commit touches something outside every manifest build_dir
        "unrelated" | save -f ($root | path join "README.md")
        ^git -C $root add -A
        ^git -C $root commit -q -m unrelated

        let out = (run-action ["check" "--repo" $root "--since" $base_sha])

        assert-eq $out.exit_code 0
        assert-str-contains $out.stdout "nothing to check" "a --since with no touched module must say so and exit 0, not silently check everything"
    })

    (run-case "cli/rebuild-reports-no-toolchain-without-crashing-when-go-absent" {
        # Simulates the no-toolchain path deterministically (rather than
        # requiring an actual Go-less machine) by pointing PATH at an empty
        # directory for the duration of the call.
        let empty_path = (make-sandbox "no-go-path")
        let root = (widget-repo "rebuild-no-go")
        write-timestamped ($root | path join "hotkeyd/hotkeyd") "bin" "2026-01-01 00:00:00"
        write-timestamped ($root | path join "hotkeyd/hotkeyd.go") "package main" "2026-01-02 00:00:00" # stale on purpose: source newer

        let out = (with-env {PATH: [$empty_path]} {
            do { ^$nu.current-exe (action-path) "rebuild" "--repo" $root "--modules" "hotkeyd" } | complete
        })

        assert-eq $out.exit_code 1
        assert-str-contains ($out.stdout + $out.stderr) "no Go toolchain" "must say so, not silently skip"
    })
]

$cases | to json
