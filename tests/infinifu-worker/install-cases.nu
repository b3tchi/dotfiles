#!/usr/bin/env nu
# Packaging cases (sp028 T7).
#
# Two things are checked here: that the worker CLI actually works when invoked
# the way an installed binary is invoked (not just as an imported module), and
# that the installer's worker step links it, reports missing dependencies
# usefully, and leaves nothing behind when it refuses.
#
# Installer cases run against a FAKE HOME so nothing touches the real
# ~/.local/bin or ~/.claude.

use harness.nu *

def worker-cli []: nothing -> string { worker-script $env.FILE_PWD }

def installer []: nothing -> string {
    repo-root $env.FILE_PWD | path join "claude" "marketplace" "plugins" "infinifu" "install.sh"
}

# Run the CLI as a subprocess, the way the linked binary is run.
def run-cli [...args: string, --runtime: string = "", --path: string = ""]: nothing -> record {
    let env_extra = if ($runtime | is-empty) { {} } else { {XDG_RUNTIME_DIR: $runtime} }
    with-env $env_extra {
        ^$nu.current-exe (worker-cli) ...$args | complete
    }
}

def fake-home [tag: string]: nothing -> string {
    let home = ([$nu.temp-dir $"infinifu-t7-home-($tag)-(random chars --length 6)"] | path join)
    rm -rf $home
    mkdir $home
    $home
}

# The installer's worker step, against a fake HOME and a controlled PATH.
def run-installer [home: string, --path-dirs: list<string> = []]: nothing -> record {
    let path = (if ($path_dirs | is-empty) { $env.PATH } else { $path_dirs })
    with-env {HOME: $home, PATH: $path} {
        ^bash (installer) worker | complete
    }
}

let cases = [
    # ------------------------------------------------------- the CLI is real
    (run-case "cli/reports-its-verbs-when-invoked-with-no-arguments" {
        # A linked binary that does nothing when run is not a CLI. This is the
        # gap that made the existing installer's script-linking inert for this
        # module: it had exported functions and no entry point.
        let out = (run-cli)
        assert-eq $out.exit_code 0 $"usage should succeed: ($out.stderr)"
        for verb in ["spawn" "send" "wait" "ack" "status" "inspect" "resume" "accept" "stop"] {
            assert-true ($out.stdout | str contains $verb) $"usage must list '($verb)'"
        }
    })

    (run-case "cli/status-of-an-unknown-worker-is-json-not-a-crash" {
        let root = (make-runtime "cli-status")
        let out = (run-cli "status" "nobody" "--run" "r1" --runtime $root)
        assert-eq $out.exit_code 0 $"($out.stderr)"
        let parsed = ($out.stdout | from json)
        assert-eq $parsed.state "unknown" "an unknown worker reports unknown"
        rm -rf $root
    })

    (run-case "cli/wait-on-an-empty-run-exits-cleanly-with-no-output" {
        # Scripting the pipeline means `wait` has to be usable in a conditional.
        let root = (make-runtime "cli-wait")
        let out = (run-cli "wait" "--run" "r1" --runtime $root)
        assert-eq $out.exit_code 0 "no mail is not a failure"
        assert-eq ($out.stdout | str trim) "" "and produces nothing to parse"
        rm -rf $root
    })

    (run-case "cli/an-unknown-verb-fails-loudly-and-names-the-verbs" {
        let out = (run-cli "teleport")
        assert-true ($out.exit_code != 0) "an unknown verb must not exit 0"
        let said = ($out.stdout + $out.stderr)
        assert-true ($said | str contains "teleport") "the failure names what was asked for"
        assert-true ($said | str contains "spawn") "and what is available"
    })

    (run-case "cli/a-missing-runtime-directory-is-an-actionable-error" {
        # XDG_RUNTIME_DIR unset is a real state on a bare ssh session, and the
        # message has to say what to set rather than failing deep in a path join.
        let out = (with-env {XDG_RUNTIME_DIR: null} { ^$nu.current-exe (worker-cli) "status" "u" "--run" "r1" | complete })
        assert-true ($out.exit_code != 0) "it must fail, not guess a directory"
        assert-true (($out.stdout + $out.stderr) | str contains "XDG_RUNTIME_DIR") "and name the variable"
    })

    (run-case "cli/doctor-reports-each-dependency-separately" {
        # One combined "something is missing" is useless at 3am; the operator
        # needs to know WHICH.
        let root = (make-runtime "doctor")
        let out = (run-cli "doctor" --runtime $root)
        let said = ($out.stdout + $out.stderr)
        for dep in ["nushell" "tmux" "XDG_RUNTIME_DIR"] {
            assert-true ($said | str contains $dep) $"doctor must report on ($dep)"
        }
        rm -rf $root
    })

    # ------------------------------------------------------------- installer
    (run-case "install/links-the-worker-cli-into-local-bin" {
        let home = (fake-home "link")
        let out = (run-installer $home)
        assert-eq $out.exit_code 0 $"installer failed: ($out.stderr)"

        let linked = ($home | path join ".local" "bin" "infinifu-worker")
        assert-true ($linked | path exists) "the CLI is linked"
        # install.sh resolves to the main worktree on purpose, so the link
        # keeps working after a feature worktree is removed. Assert that
        # contract rather than this branch's path.
        let target = (^readlink $linked | str trim)
        assert-true ($target | str ends-with "claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu") $"unexpected link target: ($target)"
        assert-true ($target | str starts-with "/") "the link is absolute"
        assert-true (not ($target | str contains ".worktrees")) "and anchored outside any feature worktree"
        rm -rf $home
    })

    (run-case "install/the-linked-cli-is-executable-and-runs" {
        # A link is not enough — the target has to carry the executable bit,
        # or the shell reports 'permission denied' and the link looks fine.
        let home = (fake-home "exec")
        run-installer $home
        let linked = ($home | path join ".local" "bin" "infinifu-worker")
        assert-true ($linked | path exists) "the link exists"
        # Executability is a property of the target file in THIS branch; the
        # link itself resolves to the main worktree, whose copy only carries
        # this change after the merge.
        assert-true ((mode-of (worker-cli)) | str contains "x") $"the CLI must be executable, got (mode-of (worker-cli))"
        let out = (^$nu.current-exe (worker-cli) | complete)
        assert-eq $out.exit_code 0 "and runs as a command"
        assert-true ($out.stdout | str contains "spawn") ""
        rm -rf $home
    })

    (run-case "install/is-idempotent" {
        let home = (fake-home "twice")
        run-installer $home
        let first = (^readlink ($home | path join ".local" "bin" "infinifu-worker") | str trim)
        let out = (run-installer $home)
        assert-eq $out.exit_code 0 "a second run succeeds"
        assert-eq (^readlink ($home | path join ".local" "bin" "infinifu-worker") | str trim) $first "and changes nothing"
        rm -rf $home
    })

    (run-case "install/links-the-pi-extension-only-when-pi-is-present" {
        # Claude-only installations must be unaffected: no Pi config directory
        # means no Pi artifacts, and no failure either.
        let home = (fake-home "nopi")
        let out = (run-installer $home)
        assert-eq $out.exit_code 0 "a Claude-only install still succeeds"
        assert-true (not (($home | path join ".config" "pi") | path exists)) "and creates no Pi config"
        assert-true (($out.stdout | str contains "Pi not detected") or ($out.stdout | str contains "skipping Pi")) "but says why it skipped"
        rm -rf $home
    })

    (run-case "install/links-the-pi-extension-when-pi-config-exists" {
        let home = (fake-home "withpi")
        mkdir ($home | path join ".config" "pi")
        let out = (run-installer $home)
        assert-eq $out.exit_code 0 $"($out.stderr)"

        let ext = ($home | path join ".config" "pi" "extensions" "infinifu.ts")
        assert-true ($ext | path exists) "the extension is linked"
        let target = (^readlink $ext | str trim)
        assert-true ($target | str ends-with "claude/marketplace/plugins/infinifu/extensions/pi.ts") $"unexpected extension target: ($target)"
        assert-true (not ($target | str contains ".worktrees")) "anchored outside any feature worktree"
        rm -rf $home
    })

    (run-case "install/warns-when-local-bin-is-not-on-path" {
        # The link succeeds and the command still is not found. Silence here
        # produces a confusing 'command not found' much later.
        let home = (fake-home "nopath")
        let out = (run-installer $home --path-dirs ["/usr/bin" "/bin"])
        assert-true ($out.stdout | str contains "PATH") "the installer says the link is not reachable"
        rm -rf $home
    })

    (run-case "install/refuses-without-nushell-and-leaves-nothing-behind" {
        # Missing dependency must fail BEFORE creating anything: a half-install
        # that links a CLI which cannot run is worse than no install.
        let home = (fake-home "nonu")
        let stub = ([$nu.temp-dir $"infinifu-t7-emptybin-(random chars --length 6)"] | path join)
        mkdir $stub
        # A PATH with neither nu nor tmux, but with the coreutils the script needs.
        for tool in ["bash" "ln" "mkdir" "readlink" "basename" "dirname" "command" "rm" "git" "awk" "sed"] {
            let found = (do { ^which $tool } | complete)
            if $found.exit_code == 0 { ^ln -sf ($found.stdout | str trim) ($stub | path join $tool) }
        }
        let out = (run-installer $home --path-dirs [$stub])

        assert-true ($out.exit_code != 0) "it must refuse"
        assert-true ((($out.stdout + $out.stderr) | str contains "nu")) "and name the missing dependency"
        assert-true (not (($home | path join ".local" "bin" "infinifu-worker") | path exists)) "and link nothing"
        rm -rf $home; rm -rf $stub
    })
]

$cases | to json
