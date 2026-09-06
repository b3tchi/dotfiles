#!/usr/bin/env nu
# Stage registry cases (dotfiles-lz7s.1).
#
# The bus used to hardcode three tables of infinifu vocabulary: WORK_STAGES,
# WORKER_SKILLS (skill -> akm|work) and STAGE_VERDICTS ("SRE PASS"). That made a
# generic transport — spawn an agent in a tmux window, message it over a file
# bus, take a typed result back — unusable by anything but one lifecycle
# framework, and it is why the two were welded together in the first place.
#
# The registry is the seam. The bus enforces whatever it says and knows nothing
# about what the names mean. Vocabulary is deliberately generic:
#
#   isolation  worktree | main    where the worker runs
#   payload    ticket | instructions   what its message may carry
#
# Nothing here says whether a result is GOOD. The bus carries a worker's
# report; judging it belongs to the consumer, on receipt.

use ../../claude/marketplace/plugins/pi-workers/scripts/stage-registry.nu *
use harness.nu *

def fixture [tag: string, body: string]: nothing -> string {
    let path = ([$nu.temp-dir $"pi-worker-stages-($tag)-(random chars --length 6).json"] | path join)
    $body | save -f $path
    $path
}

let cases = [
    (run-case "registry/loads-the-stages-a-consumer-declares" {
        let path = (fixture "load" '{"stages":[
            {"name":"build","isolation":"worktree","payload":"ticket"},
            {"name":"review","isolation":"main","payload":"instructions"}
        ]}')
        let stages = (load-stages --path $path)
        assert-eq ($stages | length) 2 "both stages"
        assert-eq ($stages | where name == "review" | first | get isolation) "main" ""
        rm -f $path
    })

    (run-case "registry/an-unknown-stage-is-refused-not-defaulted" {
        # A worker with no contract to follow burns a model turn and reports
        # nothing useful. Refusing is the whole point of having a registry.
        let path = (fixture "unknown" '{"stages":[{"name":"build","isolation":"worktree","payload":"ticket"}]}')
        assert-rejects { stage-for "nosuchstage" --path $path } "nosuchstage" "the refusal names the stage"
        assert-rejects { stage-for "nosuchstage" --path $path } "build" "and lists what is registered"
        rm -f $path
    })

    (run-case "registry/a-missing-registry-fails-closed-and-says-how-to-fix-it" {
        # Not an empty registry — an ABSENT one. Treating that as "no stages
        # configured, allow anything" would silently drop every gate the
        # consumer declared.
        let path = ([$nu.temp-dir $"pi-worker-absent-(random chars --length 6).json"] | path join)
        assert-rejects { load-stages --path $path } "no stage registry" "it says what is missing"
        assert-rejects { load-stages --path $path } $path "naming the path it looked at"
    })

    (run-case "registry/a-malformed-entry-is-rejected-rather-than-half-read" {
        # A typo'd isolation must not silently become "not worktree, so main" —
        # that would put a code worker in the shared tree.
        let bad_iso = (fixture "badiso" '{"stages":[{"name":"build","isolation":"wrktree","payload":"ticket"}]}')
        assert-rejects { load-stages --path $bad_iso } "isolation" "isolation is checked"

        let bad_payload = (fixture "badpay" '{"stages":[{"name":"build","isolation":"main","payload":"tickets"}]}')
        assert-rejects { load-stages --path $bad_payload } "payload" "payload is checked"

        let no_name = (fixture "noname" '{"stages":[{"isolation":"main","payload":"ticket"}]}')
        assert-rejects { load-stages --path $no_name } "name" "a nameless stage is unusable"
        rm -f $bad_iso; rm -f $bad_payload; rm -f $no_name
    })

    (run-case "registry/duplicate-stage-names-are-refused" {
        # Two entries claiming one name means the gate that applies is a
        # file-order accident.
        let path = (fixture "dupe" '{"stages":[
            {"name":"build","isolation":"worktree","payload":"ticket"},
            {"name":"build","isolation":"main","payload":"instructions"}
        ]}')
        assert-rejects { load-stages --path $path } "build" "the duplicate is named"
        rm -f $path
    })

    (run-case "registry/the-path-comes-from-the-environment-when-not-given" {
        # So a consumer can install its registry once and every call agrees,
        # and so tests never touch a real one.
        let path = (fixture "env" '{"stages":[{"name":"envstage","isolation":"main","payload":"instructions"}]}')
        with-env {PI_WORKER_STAGES: $path} {
            assert-eq (stage-for "envstage" | get isolation) "main" "resolved without an explicit --path"
        }
        rm -f $path
    })

    (run-case "registry/nothing-in-the-registry-contract-names-a-lifecycle" {
        # The regression guard for the split itself. If akm, bd or a stage name
        # reappears in the bus's own vocabulary, the coupling is back.
        let src = (open --raw (repo-root $env.FILE_PWD | path join "claude" "marketplace" "plugins" "pi-workers" "scripts" "stage-registry.nu"))
        for banned in ["akm" "bd show" "doc-plan" "wk-build" "SRE PASS" "verdict"] {
            assert-true (not ($src | str contains $banned)) $"the bus must not know about '($banned)'"
        }
    })
]

$cases | to json
