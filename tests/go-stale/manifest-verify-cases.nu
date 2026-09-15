#!/usr/bin/env nu
# Manifest self-check cases for go-stale (dotfiles-xwg0, rejection #1 gap 1).
#
# manifest-coverage-warnings (tested in cli-cases.nu) catches a dot.yaml
# GAINING a `go build` with no manifest row. It does NOT catch an EXISTING
# row whose dot.yaml build target CHANGES while the row/key stay put — that
# is what declared-artifact-basename / verify-manifest exist to catch: a
# manifest row that has quietly drifted from what its own dot.yaml actually
# builds.
#
# Two halves: synthetic dot.yaml TEXT fixtures for declared-artifact-basename
# (covers every shell idiom this repo's real dot.yaml files use, plus the
# gopass two-binaries-one-file disambiguation), and a real-files sandbox for
# verify-manifest's OK/DRIFT/UNRECOGNIZED classification. The load-bearing
# case is "a manifest row disagrees with its dot.yaml -> DRIFT, named" — RED
# is proven against a fixture this suite controls (not live repo dot.yaml
# content, which is fine to also assert against separately since dot.yaml
# TEXT — unlike a built binary's mtime — doesn't change under a running
# test).

use harness.nu *
use ../../nushell/actions/go-stale declared-artifact-basename
use ../../nushell/actions/go-stale verify-manifest
use ../../nushell/actions/go-stale go-modules

# ---- declared-artifact-basename: one fixture string per real idiom ----

def direct_o_dot_yaml [] {
    "linux:\n  installs:\n    cmd: |\n      go build -C \"$SRC\" -o ~/.local/bin/akm-graph-d .\n"
}

def temp_then_mv_dot_yaml [] {
    "linux:\n  installs:\n    cmd: |\n      if CGO_ENABLED=0 go build -C \"$SRC\" -o \"$TMP\" ./cmd/agent-monitor; then\n        mv -f \"$TMP\" \"$SRC/agent-monitor\"\n      fi\n"
}

def cd_and_go_build_dot_yaml [] {
    # gopass/dot.yaml's real shape: two builds, one file. Disambiguated by
    # build_dir's basename ("secretservice" / "relay") appearing on the
    # matching line.
    "linux:\n  installs:\n    cmd: |\n      (cd \"$DOT_DIR/secretservice\" && go build -o \"$HOME/.local/bin/gopass-secretservice\" .)\n      (cd \"$DOT_DIR/relay\" && go build -o \"$HOME/.local/bin/canvas-mcp-relay\" .)\n"
}

def commented_out_go_build_dot_yaml [] {
    # A comment line mentioning "go build widget" must not be mistaken for
    # the real build line.
    "linux:\n  installs:\n    cmd: |\n      # historical note: go build widget used to live here\n      echo widget: no build configured\n"
}

let cases = [
    (run-case "verify/direct-o-token-extracted" {
        let got = (declared-artifact-basename (direct_o_dot_yaml) "akm-graph")
        assert-eq $got "akm-graph-d"
    })

    (run-case "verify/temp-then-mv-resolved-to-final-destination" {
        let got = (declared-artifact-basename (temp_then_mv_dot_yaml) "agent-monitor")
        assert-eq $got "agent-monitor"
    })

    (run-case "verify/cd-and-go-build-disambiguates-secretservice" {
        let got = (declared-artifact-basename (cd_and_go_build_dot_yaml) "gopass/secretservice")
        assert-eq $got "gopass-secretservice"
    })

    (run-case "verify/cd-and-go-build-disambiguates-relay-not-secretservice" {
        let got = (declared-artifact-basename (cd_and_go_build_dot_yaml) "gopass/relay")
        assert-eq $got "canvas-mcp-relay"
    })

    (run-case "verify/comment-mentioning-go-build-is-not-mistaken-for-a-build-line" {
        let got = (declared-artifact-basename (commented_out_go_build_dot_yaml) "widget")
        assert-eq $got null
    })
]

# ---- verify-manifest: OK / DRIFT / UNRECOGNIZED against real files ----

def sandbox-with-one-module [tag: string, dot_yaml_body: string] {
    let root = (make-sandbox $"verify-($tag)")
    mkdir ($root | path join "widget")
    $dot_yaml_body | save -f ($root | path join "widget/dot.yaml")
    $root
}

let widget_row = {
    key: "widget"
    dot_yaml: "widget/dot.yaml"
    artifact: "widget/widget"
    build_dir: "widget"
    build_pkg: "."
    cgo_disabled: false
    sources: ["widget/*.go"]
}

let more_cases = [
    # THE load-bearing case: a manifest row's artifact no longer matches
    # what its own dot.yaml builds -> DRIFT, named with both the manifest's
    # (wrong) claim and the dot.yaml's real one.
    (run-case "verify/drift-when-dot-yaml-artifact-does-not-match-manifest-row" {
        let root = (sandbox-with-one-module "drift" "linux:\n  installs:\n    cmd: |\n      go build -C \"$SRC\" -o ~/.local/bin/widget-renamed .\n")
        # Reach past go-modules() (fixed to the real 7-module manifest) the
        # same way rebuild-module's own test does: call verify-manifest's
        # logic directly against one synthetic row instead of the module
        # picking one of the real seven.
        let dot_yaml_content = (open --raw ($root | path join "widget/dot.yaml"))
        let declared = (declared-artifact-basename $dot_yaml_content $widget_row.build_dir)
        let expected = ($widget_row.artifact | path basename)
        assert-true ($declared != $expected) "a renamed -o target must not match the unchanged manifest row"
        assert-eq $declared "widget-renamed"
    })

    (run-case "verify/ok-when-dot-yaml-artifact-matches-manifest-row" {
        let root = (sandbox-with-one-module "ok" "linux:\n  installs:\n    cmd: |\n      go build -C \"$SRC\" -o ~/.local/bin/widget .\n")
        let dot_yaml_content = (open --raw ($root | path join "widget/dot.yaml"))
        let declared = (declared-artifact-basename $dot_yaml_content $widget_row.build_dir)
        assert-eq $declared ($widget_row.artifact | path basename)
    })

    (run-case "verify/unrecognized-when-dot-yaml-has-no-parseable-build-line" {
        let root = (sandbox-with-one-module "unrec" "linux:\n  installs:\n    cmd: |\n      echo nothing to build here\n")
        let dot_yaml_content = (open --raw ($root | path join "widget/dot.yaml"))
        let declared = (declared-artifact-basename $dot_yaml_content $widget_row.build_dir)
        assert-eq $declared null
    })

    # Integration proof against the REAL repo's dot.yaml files (safe to run
    # against live content, unlike mtimes: dot.yaml TEXT doesn't drift
    # while a test runs). If this ever fails it means either a real
    # dot.yaml's build line changed shape, or the manifest itself drifted —
    # exactly the condition this feature exists to catch.
    (run-case "verify/real-repo-manifest-currently-matches-its-dot-yaml-files" {
        let repo_root = ($env.FILE_PWD | path join "../.." | path expand)
        let results = (verify-manifest $repo_root)
        assert-eq (go-modules | length) ($results | length)
        let bad = ($results | where status != "OK")
        assert-true ($bad | is-empty) $"expected every manifest row to verify OK against its dot.yaml, got: ($bad | to nuon)"
    })
]

($cases ++ $more_cases) | to json
