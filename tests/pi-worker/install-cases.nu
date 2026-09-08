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
use ../../claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu *

def worker-cli []: nothing -> string { worker-script $env.FILE_PWD }

def installer []: nothing -> string {
    repo-root $env.FILE_PWD | path join "claude" "marketplace" "plugins" "pi-workers" "install.sh"
}

# Run the CLI as a subprocess, the way the linked binary is run.
def run-cli [...args: string, --runtime: string = "", --path: string = ""]: nothing -> record {
    let env_extra = if ($runtime | is-empty) { {} } else { {XDG_RUNTIME_DIR: $runtime} }
    with-env $env_extra {
        ^$nu.current-exe (worker-cli) ...$args | complete
    }
}

# A hermetic PATH: the coreutils the installer needs, plus whichever of nu /
# tmux / pi the case wants present. Nothing here touches a real Pi install --
# the `pi` stub records its argv so a case can assert on the CONTRACT the
# installer uses rather than on a live Pi's side effects.
def stub-bin [
    tag: string
    --tools: list<string> = []
    --record-pi
    --pi-already-installed
    # Bytes of extra package lines for `pi list` to print. A real Pi install
    # lists every package, and the probe has to survive a long list.
    --noise: int = 0
]: nothing -> string {
    let bin = ([(fixture-base) $"piw-t7-bin-($tag)-(random chars --length 6)"] | path join)
    rm -rf $bin
    mkdir $bin
    let base = ["bash" "ln" "mkdir" "readlink" "basename" "dirname" "rm" "git" "awk" "sed" "grep" "cat" "which" "env" "sort" "head" "tail" "tr" "cut" "cp" "mv" "test" "printf" "echo"]
    for tool in ($base | append $tools) {
        let found = (do { ^which $tool } | complete)
        if $found.exit_code == 0 { ^ln -sf ($found.stdout | str trim) ($bin | path join $tool) }
    }
    if $record_pi {
        let log = ($bin | path join "pi-calls.log")
        touch $log
        # `pi list` reports the resolved absolute path on its own line, which is
        # what an idempotence check can match against.
        # Filler lines AFTER the real entry: that is the shape that breaks a
        # probe which stops reading at the match, because the commands upstream
        # of it still have the rest of the list to write.
        let filler = (
            if $noise <= 0 { "" } else {
                let line = $"    /home/someone/.pi/packages/(random chars --length 40)"
                (0..(($noise / (($line | str length) + 1)) | into int))
                | each {|i| $"    /home/someone/.pi/packages/package-($i)-(random chars --length 30)" }
                | str join "\n"
                | append "\n"
                | str join ""
            }
        )
        let listed = if $pi_already_installed {
            # The path install.sh will actually use, asked of git rather than
            # predicted from where this test happens to live.
            $"  ../../pi-workers\n    (main-package-dir)\n($filler)"
        } else { $filler }
        let script = ([
            "#!/usr/bin/env bash"
            $"echo \"$*\" >> '($log)'"
            "if [ \"${1:-}\" = list ]; then"
            "  echo 'User packages:'"
            $"  printf '%b\\n' '($listed)'"
            "fi"
            "exit 0"
        ] | str join "\n")
        $script | save -f ($bin | path join "pi")
        ^chmod +x ($bin | path join "pi")
    }
    $bin
}

def fake-home [tag: string]: nothing -> string {
    let home = ([(fixture-base) $"piw-t7-home-($tag)-(random chars --length 6)"] | path join)
    rm -rf $home
    mkdir $home
    $home
}

# The installer's worker step, against a fake HOME and a controlled PATH.
def run-installer [home: string, --path-dirs: list<string> = []]: nothing -> record {
    let path = (if ($path_dirs | is-empty) { $env.PATH } else { $path_dirs })
    with-env {HOME: $home, PATH: $path} {
        ^bash (installer) | complete
    }
}

# A throwaway repo holding a copy of this plugin, busy enough that
# `git worktree list --porcelain` needs more than one write to report it.
#
# That size is the point, and it is measured rather than assumed. install.sh
# resolves the main worktree so its link survives a feature worktree being
# removed, and it did that by piping the porcelain listing into an `awk` that
# exits on the first record. Past one write buffer git is still writing when awk
# closes the pipe, which is a SIGPIPE, and under `set -euo pipefail` git's 141
# becomes the installer's exit status.
#
# Measured on this box: 3891 bytes of listing passed 8/8 runs, 6135 bytes failed
# 8/8 — a 4 KiB buffer. Calibrating on BYTES rather than on a worktree count is
# deliberate: the record length depends on how long $TMPDIR happens to be, so a
# fixed count of 32 worktrees straddled the threshold and made a real installer
# bug look like a flaky test. This repo carried 31 entries the day it was found.
def repo-with-worktrees [tag: string, bytes: int]: nothing -> record {
    let repo = ([(fixture-base) $"piw-t7-repo-($tag)-(random chars --length 6)"] | path join)
    let plugins = ($repo | path join "claude" "marketplace" "plugins")
    let plugin = ($plugins | path join "pi-workers")
    rm -rf $repo
    mkdir $plugins
    cp -r (main-package-dir) $plugins
    ^git init -q -b main $repo
    ^git -C $repo config user.email "test@example.com"
    ^git -C $repo config user.name "Test"
    ^git -C $repo add -A
    ^git -C $repo commit -q -m "the plugin, as installed from"
    # Grown until the listing is past the target, so the fixture holds however
    # many worktrees THIS machine's paths need to get there.
    mut i = 0
    while (^git -C $repo worktree list --porcelain | str length) < $bytes {
        $i = $i + 1
        if $i > 500 { error make {msg: $"could not grow the listing past ($bytes) bytes"} }
        ^git -C $repo worktree add -q -b $"wt-($i)" ($repo | path join ".worktrees" $"wt-($i)")
    }
    {repo: $repo, installer: ($plugin | path join "install.sh"), worktrees: $i}
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

    (run-case "cli/every-verb-names-the-flag-it-is-missing" {
        # `--run` and friends were declared `string` with no default across the
        # whole surface, so omitting one propagated a NULL inward until some
        # helper died on it:
        #
        #     Error: nu::shell::cant_convert
        #       x Can't convert to string.
        #
        # which names no verb, no flag and no remedy. `main spawn` documents
        # exactly this and guards against it; a sweep found 15 of 17 verbs did
        # not, and one of them cost an operator a stuck worker and a retry loop
        # (dotfiles-kuw5).
        #
        # Data-driven on purpose: the invariant is about the SURFACE, so a new
        # verb that forgets the guard fails here rather than in a live run.
        let root = (make-runtime "flag-refusals")
        let probes = [
            [verb, args];
            ["send"     ["send" "w1"]]
            ["wait"     ["wait"]]
            ["ack"      ["ack"]]
            ["result"   ["result" "w1"]]
            ["settled"  ["settled" "w1"]]
            ["liveness" ["liveness" "w1"]]
            ["status"   ["status" "w1"]]
            ["inspect"  ["inspect" "w1"]]
            ["timeline" ["timeline" "w1"]]
            ["rm"       ["rm"]]
            ["workers"  ["workers"]]
            ["resume"   ["resume" "w1"]]
            ["respawn"  ["respawn" "w1"]]
            ["accept"   ["accept" "w1"]]
            ["stop"     ["stop" "w1"]]
            ["spawn"    ["spawn" "--role" "impl"]]
        ]
        for p in $probes {
            let out = (run-cli ...$p.args --runtime $root)
            assert-true ($out.exit_code != 0) $"($p.verb) with nothing passed should refuse"
            let err = ($out.stderr | str trim)
            assert-true (not ($err | str contains "Can't convert")) $"($p.verb) leaked a null instead of refusing: ($err)"
            assert-true ($err | str contains $"($p.verb) needs --") $"($p.verb) must name the flag it wants: ($err)"
        }
    })

    (run-case "cli/a-worker-reporting-from-its-own-window-needs-no-address" {
        # `result` and `settled` are the WORKER's verbs, and a worker runs with
        # PI_WORKER_RUN and PI_WORKER_UID in its environment — spawn puts them
        # there. Making it pass its own address back is ceremony, and getting it
        # wrong is how a report lands on someone else's mail.
        let root = (make-runtime "worker-env")
        with-env {XDG_RUNTIME_DIR: $root} {
            bus-identity "impl-1" --run "r1" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                session: "sid-1", skill: "doc-draft", window: "impl-t@dotfiles"
            }
        }
        let out = (with-env {PI_WORKER_RUN: "r1", PI_WORKER_UID: "impl-1"} {
            run-cli "result" "--status" "complete" "--summary" "reported without an address" --runtime $root
        })
        assert-eq $out.exit_code 0 $"result should derive its address: ($out.stderr | str trim)"
        with-env {XDG_RUNTIME_DIR: $root} {
            assert-eq (bus-status "impl-1" --run "r1" | get state) "complete" "and the report lands on the right worker"
        }
    })

    (run-case "cli/repo-is-derived-when-omitted-rather-than-arriving-as-null" {
        # Observed live, on the operator's own screen:
        #
        #     accept refused: Can't convert to string.
        #
        # `--repo` was declared `string` with no default, so omitting it
        # propagated a NULL inward until expand-path died on it — the exact
        # failure `main spawn` already documents and guards against, in three
        # verbs that never got the same treatment. The message names no verb,
        # no flag and no remedy, and the worker sat `complete` in the frame
        # while its orchestrator retried.
        #
        # Derived from the cwd, like spawn does: it is not a decision the
        # caller was making.
        let root = (make-runtime "derive-repo")
        for verb in [["accept" ["accept" "nobody" "--run" "r1"]] ["respawn" ["respawn" "nobody" "--run" "r1"]]] {
            let out = (run-cli ...($verb | get 1) --runtime $root)
            assert-true ($out.exit_code != 0) $"($verb | get 0) should refuse an unknown worker"
            let err = ($out.stderr | str trim)
            assert-true (not ($err | str contains "Can't convert")) $"($verb | get 0) leaked a null: ($err)"
            # It got far enough to ask the bus, which is the proof the repo was
            # resolved rather than passed on as null.
            assert-true ($err | str contains "no identity") $"($verb | get 0) should fail on the worker, not the flag: ($err)"
        }
        # reclaim takes no uid, so a derived repo means it runs and reports.
        let swept = (run-cli "reclaim" "--dry-run" --runtime $root)
        assert-eq $swept.exit_code 0 $"reclaim should have derived its repo: ($swept.stderr | str trim)"
        assert-true (($swept.stdout | from json | get repo) | is-not-empty) "and say which repo it swept"
    })

    (run-case "cli/a-verb-that-cannot-derive-a-repo-refuses-by-name" {
        # Outside a repository there is nothing to derive, and THAT is worth a
        # refusal — one that names the flag and what it is for, rather than a
        # type error from four calls deeper.
        let root = (make-runtime "no-repo")
        let outside = ((fixture-base) | path join $"outside-(random chars --length 6)")
        mkdir $outside
        cd $outside
        let out = (run-cli "accept" "nobody" "--run" "r1" --runtime $root)
        assert-true ($out.exit_code != 0) ""
        let err = ($out.stderr | str trim)
        assert-true ($err | str contains "--repo") $"the refusal must name the flag: ($err)"
        assert-true (not ($err | str contains "Can't convert")) $"and must not be a type error: ($err)"
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
    # ------------------------------------------- the return path is reachable
    #
    # dotfiles-87bt: `bus-result` and the settle reporter existed as nu
    # functions with no CLI surface, and the extension registered no tool, so a
    # worker had NO way to report an outcome by any route — while
    # wk-build/SKILL.md instructed every worker to "finish by calling the typed
    # result tool". These cases pin the CLI half: whatever the extension does,
    # a worker or a stub must be able to report from a shell.

    (run-case "cli/result-writes-an-outcome-a-waiting-initiator-can-read" {
        let root = (make-runtime "cli-result")
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "wk-t1.0"
                session: "sid-1", skill: "wk-build", window: "impl-a@dotfiles"
            }
        }
        let out = (run-cli "result" "impl-a" "--run" "r1" "--status" "complete"
            "--summary" "did the thing" "--validation" "TESTS PASS" --runtime $root)
        assert-eq $out.exit_code 0 $"($out.stderr)"

        # The initiator's own verb must see it — reporting that only the writer
        # can read is not reporting.
        let waited = (run-cli "wait" "--run" "r1" --runtime $root)
        assert-eq $waited.exit_code 0 $"($waited.stderr)"
        let envelope = ($waited.stdout | from json)
        assert-eq $envelope.kind "result" "wait returns the result envelope"
        assert-eq $envelope.payload.status "complete" "carrying the reported status"
        assert-eq $envelope.payload.validation "TESTS PASS" "and its verdict"
        rm -rf $root
    })

        (run-case "cli/result-refuses-a-status-only-the-initiator-may-grant" {
        # adr0017 / T6: `accepted` is the initiator's verdict. A worker that
        # could self-accept could close its own task.
        let root = (make-runtime "cli-accept")
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "wk-t1.0"
                session: "sid-1", skill: "wk-build", window: "impl-a@dotfiles"
            }
        }
        let out = (run-cli "result" "impl-a" "--run" "r1" "--status" "accepted"
            "--summary" "I accept myself" --runtime $root)

        assert-true ($out.exit_code != 0) "self-acceptance must be refused"
        rm -rf $root
    })

    (run-case "cli/settled-turns-a-silent-worker-into-a-readable-protocol-error" {
        # The failure this exists to prevent: a worker settles having reported
        # nothing, and the initiator waits forever on a worker that is done.
        let root = (make-runtime "cli-settled")
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "wk-t1.0"
                session: "sid-1", skill: "wk-build", window: "impl-a@dotfiles"
            }
        }
        let out = (run-cli "settled" "impl-a" "--run" "r1" --runtime $root)
        assert-eq $out.exit_code 0 $"($out.stderr)"

        let waited = (run-cli "wait" "--run" "r1" --runtime $root)
        let envelope = ($waited.stdout | from json)
        assert-eq $envelope.kind "error" "the initiator learns it settled empty"
        assert-eq $envelope.payload.code "protocol_error" "as a protocol error"
        rm -rf $root
    })

    (run-case "cli/settled-after-a-real-result-stays-quiet" {
        let root = (make-runtime "cli-settled-ok")
        with-runtime $root {
            bus-identity "impl-a" --run "r1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "wk-t1.0"
                session: "sid-1", skill: "wk-build", window: "impl-a@dotfiles"
            }
        }
        run-cli "result" "impl-a" "--run" "r1" "--status" "blocked" "--summary" "stuck" --runtime $root
        let out = (run-cli "settled" "impl-a" "--run" "r1" --runtime $root)
        assert-eq $out.exit_code 0 $"($out.stderr)"

        with-runtime $root {
            assert-eq ((read-results "impl-a" --run "r1") | length) 1 "the real outcome is not buried"
        }
        rm -rf $root
    })

    (run-case "cli/usage-lists-the-reporting-verbs" {
        # A verb absent from usage is a verb nobody finds. The whole bug was an
        # unreachable path; the usage text is part of reachability.
        let out = (run-cli)
        for verb in ["result" "settled"] {
            assert-true ($out.stdout | str contains $verb) $"usage must list '($verb)'"
        }
    })

    (run-case "install/links-the-worker-cli-into-local-bin" {
        let home = (fake-home "link")
        let out = (run-installer $home)
        assert-eq $out.exit_code 0 $"installer failed: ($out.stderr)"

        let linked = ($home | path join ".local" "bin" "pi-worker")
        assert-true ($linked | path exists) "the CLI is linked"
        # install.sh resolves to the main worktree on purpose, so the link
        # keeps working after a feature worktree is removed. Assert that
        # contract rather than this branch's path.
        let target = (^readlink $linked | str trim)
        assert-true ($target | str ends-with "claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu") $"unexpected link target: ($target)"
        assert-true ($target | str starts-with "/") "the link is absolute"
        assert-true (not ($target | str contains ".worktrees")) "and anchored outside any feature worktree"
        rm -rf $home
    })

    (run-case "install/the-linked-cli-is-executable-and-runs" {
        # A link is not enough — the target has to carry the executable bit,
        # or the shell reports 'permission denied' and the link looks fine.
        let home = (fake-home "exec")
        run-installer $home
        let linked = ($home | path join ".local" "bin" "pi-worker")
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

    (run-case "install/runs-in-a-repo-with-many-worktrees" {
        # The installer resolves the main worktree before it links anything, so
        # a repo busy enough to make that resolution fail is a repo it cannot
        # install in at all. 8 KiB of listing is comfortably past the 4 KiB
        # write buffer where the old pipeline took a SIGPIPE every time.
        let fx = (repo-with-worktrees "busy" 8192)
        let home = (fake-home "busy")
        # `guarded`, because this fixture is ~26 MB of git worktrees and the
        # first RED runs of this very case left three of them in /tmp.
        guarded {
            let out = (with-env {HOME: $home} { ^bash $fx.installer | complete })
            assert-eq $out.exit_code 0 $"installer failed in a repo with ($fx.worktrees) worktrees: exit ($out.exit_code), stderr: ($out.stderr | str trim)"

            let linked = ($home | path join ".local" "bin" "pi-worker")
            assert-true ($linked | path exists) "and it still links the CLI"
            let target = (^readlink $linked | str trim)
            assert-true ($target | str starts-with $fx.repo) $"the link must point into the repo it was run from: ($target)"
            assert-true (not ($target | str contains ".worktrees")) "anchored in the main worktree, not a feature one"
        } { rm -rf $home; rm -rf $fx.repo }
    })

    (run-case "install/does-not-re-register-when-pi-lists-many-packages" {
        # The same defect class as the worktree listing, one function along:
        # `pi list | sed | grep -qxF` has grep exit on the first match, so past
        # one write buffer the upstream commands take a SIGPIPE and pipefail
        # reports 141 — which reads as "not registered" and installs the
        # package a second time. A wrong answer, not an abort, which is worse.
        let home = (fake-home "pi-many")
        let bin = (stub-bin "pi-many" --tools ["nu" "tmux"] --record-pi --pi-already-installed --noise 6144)
        guarded {
            let out = (run-installer $home --path-dirs [$bin])
            assert-eq $out.exit_code 0 $"installer failed: ($out.stderr | str trim)"
            assert-true ($out.stdout | str contains "already registered") $"expected the probe to see the package, got: ($out.stdout)"
            let calls = (open ($bin | path join "pi-calls.log") | lines | where {|l| $l | str starts-with "install" })
            assert-eq ($calls | length) 0 $"nothing should have been installed again, got ($calls)"
        } { rm -rf $home; rm -rf $bin }
    })

    (run-case "install/is-idempotent" {
        let home = (fake-home "twice")
        run-installer $home
        let first = (^readlink ($home | path join ".local" "bin" "pi-worker") | str trim)
        let out = (run-installer $home)
        assert-eq $out.exit_code 0 "a second run succeeds"
        assert-eq (^readlink ($home | path join ".local" "bin" "pi-worker") | str trim) $first "and changes nothing"
        rm -rf $home
    })

    (run-case "install/skips-the-pi-package-when-the-pi-binary-is-absent" {
        # Claude-only installations must be unaffected: no `pi` on PATH means
        # no Pi artifacts, and no failure either. The probe is the BINARY --
        # a config directory is not the signal, because Pi creates ~/.pi
        # lazily and never creates ~/.config/pi at all.
        let home = (fake-home "nopi")
        let bin = (stub-bin "nopi" --tools ["nu" "tmux"])
        let out = (run-installer $home --path-dirs [$bin])
        assert-eq $out.exit_code 0 "a Claude-only install still succeeds"
        assert-true (($out.stdout | str contains "Pi not detected") or ($out.stdout | str contains "skipping Pi")) "but says why it skipped"
        assert-true (not (($home | path join ".config" "pi") | path exists)) "and invents no Pi config dir"
        rm -rf $home; rm -rf $bin
    })

    (run-case "install/registers-the-plugin-as-a-pi-package-when-pi-is-present" {
        # Pi 0.84.4 has no extension drop-directory. A package is registered
        # with `pi install <source>`, which appends to `packages[]` in
        # ~/.pi/agent/settings.json. Dropping a symlink in ~/.config/pi
        # installs nothing at all.
        let home = (fake-home "withpi")
        let bin = (stub-bin "withpi" --tools ["nu" "tmux"] --record-pi)
        let out = (run-installer $home --path-dirs [$bin])
        assert-eq $out.exit_code 0 $"($out.stdout)($out.stderr)"

        let log = ($bin | path join "pi-calls.log")
        assert-true ($log | path exists) "the installer must invoke pi"
        let calls = (open $log | lines | where {|l| ($l | str trim | is-not-empty) })
        let installs = ($calls | where {|c| $c starts-with "install " })
        assert-eq ($installs | length) 1 $"exactly one `pi install`, got: ($calls | str join '; ')"

        let src = ($installs | first | str replace "install " "" | str trim)
        assert-true ($src | path exists) $"the source must be a real path: ($src)"
        assert-true (($src | path join "package.json") | path exists) $"the source must be the plugin package root: ($src)"
        assert-true (not ($src | str contains ".worktrees")) "anchored outside any feature worktree"
        rm -rf $home; rm -rf $bin
    })

    (run-case "install/registering-the-pi-package-twice-does-not-duplicate-it" {
        # `pi install` is run on every worker install. If the package is
        # already in packages[], re-running must be a no-op rather than a
        # second entry that `pi remove` then only half-clears.
        let home = (fake-home "twicepi")
        let bin = (stub-bin "twicepi" --tools ["nu" "tmux"] --record-pi --pi-already-installed)
        let out = (run-installer $home --path-dirs [$bin])
        assert-eq $out.exit_code 0 $"($out.stdout)($out.stderr)"

        let calls = (open ($bin | path join "pi-calls.log") | lines | where {|l| ($l | str trim | is-not-empty) })
        let installs = ($calls | where {|c| $c starts-with "install " })
        assert-eq ($installs | length) 0 $"already registered, so no re-install; got: ($calls | str join '; ')"
        assert-true ($out.stdout | str contains "already") "and says it was already registered"
        rm -rf $home; rm -rf $bin
    })

    (run-case "install/uninstall-removes-the-pi-package" {
        # Uninstall that leaves packages[] pointing at a path it just unlinked
        # gives Pi a broken package on the next start.
        let home = (fake-home "unpi")
        let bin = (stub-bin "unpi" --tools ["nu" "tmux"] --record-pi --pi-already-installed)
        let out = (with-env {HOME: $home, PATH: [$bin]} { ^bash (installer) uninstall | complete })
        assert-eq $out.exit_code 0 $"($out.stdout)($out.stderr)"

        let calls = (open ($bin | path join "pi-calls.log") | lines | where {|l| ($l | str trim | is-not-empty) })
        let removes = ($calls | where {|c| $c starts-with "remove " })
        assert-eq ($removes | length) 1 $"exactly one `pi remove`, got: ($calls | str join '; ')"
        rm -rf $home; rm -rf $bin
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
        let stub = ([(fixture-base) $"piw-t7-emptybin-(random chars --length 6)"] | path join)
        mkdir $stub
        # A PATH with neither nu nor tmux, but with the coreutils the script needs.
        for tool in ["bash" "ln" "mkdir" "readlink" "basename" "dirname" "command" "rm" "git" "awk" "sed"] {
            let found = (do { ^which $tool } | complete)
            if $found.exit_code == 0 { ^ln -sf ($found.stdout | str trim) ($stub | path join $tool) }
        }
        let out = (run-installer $home --path-dirs [$stub])

        assert-true ($out.exit_code != 0) "it must refuse"
        assert-true ((($out.stdout + $out.stderr) | str contains "nu")) "and name the missing dependency"
        assert-true (not (($home | path join ".local" "bin" "pi-worker") | path exists)) "and link nothing"
        rm -rf $home; rm -rf $stub
    })
]

$cases | to json
