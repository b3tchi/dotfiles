#!/usr/bin/env nu
# Completion-safety cases (sp028 T6).
#
# A false completion is the most expensive failure this system can produce: it
# closes a window, deletes a worktree, and tells the pipeline to move on. So
# the question these cases ask is not "does a valid completion work" but "can
# an INVALID one get through" — forged prose, a missing verdict, a stage-
# specific gate that was never applied, or absent evidence being read as
# permission.

use harness.nu *
use ../../claude/marketplace/plugins/infinifu/scripts/infinifu-worker.nu *

def result-for [status: string, overrides: record = {}]: nothing -> record {
    {
        status: $status
        summary: "did the thing"
        validation: (if $status == "complete" { "PASS" } else { null })
        window: "impl-a@dotfiles"
        session: "sid-1"
        resume: "pi --session sid-1"
    } | merge $overrides
}

def with-worker [tag: string, skill: string, body: closure] {
    let root = (make-runtime $tag)
    let outcome = (try {
        with-runtime $root {
            bus-identity "impl-a" --run "run-1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "bd-t1.0"
                session: "sid-1", skill: $skill, window: "impl-a@dotfiles"
            }
            do $body
        }
        null
    } catch {|e| $e })
    rm -rf $root
    if $outcome != null { error make {msg: $outcome.msg} }
}

let cases = [
    # ------------------------------------------------- stage-specific verdicts
    (run-case "completion/spec-refinement-requires-an-sre-pass" {
        # The one stage with a named gate. "looks good" is not the verdict that
        # spec-refinement's own discipline produces, and accepting it would let
        # an unrefined plan reach spec-ready.
        with-worker "sre" "spec-refinement" {
            assert-rejects {
                bus-result "impl-a" --run "run-1" --result (result-for "complete" {validation: "looks good"})
            } "SRE PASS" "spec-refinement completion must carry its own verdict"
            bus-result "impl-a" --run "run-1" --result (result-for "complete" {validation: "SRE PASS"})
        }
    })

    (run-case "completion/a-forged-pass-in-prose-is-not-a-verdict" {
        # The failure this whole typed-envelope design exists to prevent: an
        # assistant writing "SRE PASS" in its summary while the verdict field
        # is empty. The gate reads the field, never the prose.
        with-worker "forged" "spec-refinement" {
            assert-rejects {
                bus-result "impl-a" --run "run-1" --result (result-for "complete" {
                    summary: "Everything checks out. Verdict: SRE PASS. Ready to proceed."
                    validation: null
                })
            } "validation" "prose claiming a verdict is not a verdict"
        }
    })

    (run-case "completion/a-forged-pass-in-prose-does-not-satisfy-the-stage-gate" {
        # Subtler: the verdict field IS set, but to something that is not a
        # pass, while the summary says PASS. The stage gate must read the
        # field it was given.
        with-worker "forged2" "spec-refinement" {
            assert-rejects {
                bus-result "impl-a" --run "run-1" --result (result-for "complete" {
                    summary: "SRE PASS — all eight categories reviewed"
                    validation: "needs another pass"
                })
            } "SRE PASS" "the summary cannot stand in for the verdict"
        }
    })

    (run-case "completion/the-gate-never-consults-the-summary" {
        # Asserted against validate-completion DIRECTLY, not through
        # bus-result. Going through the envelope path, T1's "complete needs a
        # verdict" rule fires first and hides whether the stage gate itself
        # would have read the summary — a mutant that made the gate fall back
        # to summary text survived the whole suite for exactly that reason.
        # Two layers happening to cover one hole is not the same as the hole
        # being closed.
        assert-rejects {
            validate-completion "spec-refinement" {
                status: "complete"
                summary: "Verdict: SRE PASS. Everything checks out."
                validation: null
            }
        } "validation" "an empty verdict is empty however persuasive the prose is"

        assert-rejects {
            validate-completion "work-do" {
                status: "complete"
                summary: "all tests green, PASS"
                validation: ""
            }
        } "validation" "and that holds for every stage, not just the gated one"
    })

    (run-case "completion/the-gate-reads-only-the-verdict-field" {
        # The positive half: a verdict that satisfies the stage passes even
        # when the summary says nothing about it, proving the field is the
        # source and the prose is irrelevant in both directions.
        validate-completion "spec-refinement" {
            status: "complete"
            summary: "refined eleven tasks"
            validation: "SRE PASS"
        }
    })

    (run-case "completion/other-stages-still-require-some-verdict" {
        with-worker "workdo" "work-do" {
            assert-rejects {
                bus-result "impl-a" --run "run-1" --result (result-for "complete" {validation: ""})
            } "validation" "an empty verdict is not a verdict"
            bus-result "impl-a" --run "run-1" --result (result-for "complete" {validation: "tests green: 208 passed"})
        }
    })

    (run-case "completion/a-stage-gate-cannot-be-skipped-by-omitting-identity" {
        # If a worker could dodge its stage gate by never recording an
        # identity, the gate would be advisory. No identity means the caller
        # cannot say which stage this is, so a completion is refused outright.
        let root = (make-runtime "noident")
        with-runtime $root {
            assert-rejects {
                bus-result "ghost" --run "run-1" --result (result-for "complete")
            } "identity" "a completion from a worker with no identity is refused"
        }
        rm -rf $root
    })

    # ------------------------------------------- non-complete outcomes carry resume
    (run-case "completion/a-blocked-result-still-carries-resume-information" {
        # Validation failing after artifacts were edited but before commit is
        # the common case. The worker reports blocked, and the operator needs
        # to be able to get back into that exact session to finish.
        with-worker "blocked" "spec-refinement" {
            bus-result "impl-a" --run "run-1" --result (result-for "blocked" {
                summary: "SRE review found unsafe ordering in task 3; artifacts edited, nothing committed"
            })
            let got = (bus-wait --run "run-1")
            assert-eq $got.payload.status "blocked" ""
            assert-eq $got.payload.resume "pi --session sid-1" "a blocked worker is still resumable"
            assert-true ($got.payload.summary | str contains "nothing committed") "and says where it stopped"
        }
    })

    (run-case "completion/a-failed-stage-cannot-be-relabelled-complete-later" {
        # Envelopes are append-only; a later completion does not erase the
        # earlier failure, it is just the newer sequence. The history stays
        # auditable.
        with-worker "history" "work-do" {
            bus-result "impl-a" --run "run-1" --result (result-for "failed" {summary: "first attempt failed"})
            bus-result "impl-a" --run "run-1" --result (result-for "complete" {validation: "tests green"})
            let all = (read-results "impl-a" --run "run-1")
            assert-eq ($all | get status) ["failed" "complete"] "both outcomes remain on the record"
        }
    })

    # ------------------------------------------------------- unknown evidence
    (run-case "completion/unknown-never-licenses-stop" {
        # adr0017, applied to every destructive verb in turn. Absent evidence
        # is a reason to look again, never permission to tear down.
        let root = (make-runtime "unk-stop")
        with-runtime $root {
            assert-rejects { worker-stop "ghost" --run "run-1" } "unknown" "stop refuses an unknown worker"
        }
        rm -rf $root
    })

    (run-case "completion/unknown-never-licenses-acceptance-or-deletion" {
        let root = (make-runtime "unk-accept")
        with-runtime $root {
            assert-rejects {
                worker-accept "ghost" --run "run-1" --repo "/tmp/nowhere"
            } "unknown" "acceptance refuses an unknown worker"
            assert-rejects { worker-inspect "ghost" --run "run-1" } "unknown" "inspect reports unknown rather than inventing"
        }
        rm -rf $root
    })

    (run-case "completion/unknown-is-reported-not-persisted" {
        let root = (make-runtime "unk-state")
        with-runtime $root {
            assert-eq (bus-status "ghost" --run "run-1" | get state) "unknown" "status reports it"
            assert-true ("unknown" not-in $WORKER_STATES) "but it is not a state the machine can hold"
            assert-rejects { validate-transition "unknown" "accepted" } "observational" ""
            assert-rejects { validate-transition "unknown" "stopped" } "observational" ""
        }
        rm -rf $root
    })

    # ------------------------------------- completion after stop or acceptance
    (run-case "completion/a-result-arriving-after-stop-does-not-revive-the-worker" {
        # The worker was torn down; a late envelope must not silently move it
        # back into a live state, or an orchestrator would resume something
        # that no longer exists.
        let root = (make-runtime "late-stop")
        with-runtime $root {
            bus-identity "impl-a" --run "run-1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "bd-t1.0"
                session: "sid-1", skill: "work-do", window: "impl-a@dotfiles"
            }
            worker-stop "impl-a" --run "run-1"
            bus-result "impl-a" --run "run-1" --result (result-for "complete" {validation: "tests green"})
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "stopped" "the terminal state stands"
        }
        rm -rf $root
    })

    (run-case "completion/a-result-arriving-after-acceptance-does-not-reopen-it" {
        let root = (make-runtime "late-accept")
        with-runtime $root {
            bus-identity "impl-a" --run "run-1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "bd-t1.0"
                session: "sid-1", skill: "work-do", window: "impl-a@dotfiles"
            }
            bus-result "impl-a" --run "run-1" --result (result-for "complete" {validation: "tests green"})
            mark-accepted "impl-a" --run "run-1"
            bus-result "impl-a" --run "run-1" --result (result-for "failed" {summary: "late failure"})
            assert-eq (bus-status "impl-a" --run "run-1" | get state) "accepted" "acceptance is terminal"
        }
        rm -rf $root
    })

    # ------------------------------------------------------ transport boundary
    (run-case "completion/a-completion-is-addressed-to-the-run-waiter-only" {
        # The completion path is a file in a run-scoped directory. There is no
        # pane, window or option anywhere in it — asserted structurally, by
        # showing the envelope's whole journey is inside the run's own tree.
        let root = (make-runtime "addressed")
        with-runtime $root {
            bus-identity "impl-a" --run "run-1" --identity {
                role: "impl", cwd: "/tmp/nowhere", branch: "bd-t1.0"
                session: "sid-1", skill: "work-do", window: "impl-a@dotfiles"
            }
            bus-result "impl-a" --run "run-1" --result (result-for "complete" {validation: "green"})

            let files = (glob ((bus-root) + "/**/*.json"))
            for f in $files {
                assert-true ($f | str starts-with ((bus-root) | path join "run-1")) $"($f) escaped the run's own tree"
            }
            assert-true ((bus-wait --run "run-2") | is-empty) "another run's waiter sees nothing"
        }
        rm -rf $root
    })
]

$cases | to json
