#!/usr/bin/env nu
# Envelope schema cases (sp029 T2: envelope v2 and message ids).
#
# Every envelope crossing the bus is versioned, addressed and capped. These
# cases assert the validator rejects each way an envelope can be wrong, and —
# the half that is easy to forget — that it ACCEPTS the shapes the protocol
# actually needs, so a validator cannot pass this suite by rejecting
# everything.
#
# Emits a JSON case list on stdout; run-tests.nu aggregates.

use harness.nu *
use ../../claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu *

# 1 KiB of filler, used to build oversized content without a literal blob.
def filler [bytes: int]: nothing -> string {
    "x" | fill --width $bytes --character "x"
}

let cases = [
    # ---------------------------------------------------- accepts valid shapes
    (run-case "schema/accepts-inbox" {
        validate-envelope (sample-envelope "inbox")
    })
    (run-case "schema/accepts-result" {
        validate-envelope (sample-envelope "result")
    })
    (run-case "schema/accepts-error" {
        validate-envelope (sample-envelope "error")
    })
    (run-case "schema/accepts-identity" {
        validate-envelope (sample-envelope "identity")
    })
    (run-case "schema/accepts-arbitrary-opaque-content" {
        # ft013/sp029: the bus interprets none of a message's content. A
        # record shape that would have been refused as "not a declared
        # stage" under the old registry gate is now simply opaque data.
        validate-envelope (
            sample-envelope "inbox"
            | update content {anything: "goes", nested: {a: 1, b: [1 2 3]}}
        )
    })

    # ------------------------------------------------------- required fields
    (run-case "schema/rejects-missing-protocol" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject protocol) } "protocol" "missing version must be named"
    })
    (run-case "schema/rejects-missing-kind" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject kind) } "kind" "missing kind must be named"
    })
    (run-case "schema/rejects-missing-from" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject from) } "from" "missing sender must be named"
    })
    (run-case "schema/rejects-missing-to" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject to) } "to" "missing recipients must be named"
    })
    (run-case "schema/rejects-missing-created" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject created) } "created" "missing timestamp must be named"
    })
    (run-case "schema/rejects-missing-content" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | reject content) } "content" "missing content must be named"
    })

    # --------------------------------------------------------- version + kind
    (run-case "schema/rejects-protocol-1-naming-the-version-it-read" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | update protocol 1) } "1" "the refusal must name the version it read"
    })
    (run-case "schema/rejects-an-unknown-future-protocol" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | update protocol 3) } "protocol" "unknown version must be rejected"
    })
    (run-case "schema/rejects-unknown-kind" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | update kind "gossip") } "kind" "unknown kind must be rejected"
    })

    # --------------------------------------------------------------- from/to
    (run-case "schema/rejects-empty-from" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | update from "") } "from" "an empty sender must be refused"
    })
    (run-case "schema/rejects-empty-to" {
        # An agent may address itself and mail may name the same address
        # twice — see accepts-self-addressed and accepts-duplicate-to below —
        # but it must name SOMEONE.
        assert-rejects { validate-envelope (sample-envelope "inbox" | update to []) } "to" "an empty recipient list must be refused"
    })
    (run-case "schema/rejects-to-that-is-not-a-list" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | update to "impl-a") } "to" "a bare address is not a recipient list"
    })
    (run-case "schema/accepts-self-addressed-to" {
        # An agent addressing itself is legal — a note to self, or a
        # commissioner that is also a recipient of its own fan-out.
        validate-envelope (sample-envelope "inbox" | update to ["impl-dotfiles-963w.1-a1"])
    })
    (run-case "schema/accepts-duplicate-to" {
        # Deduplication, if any, is the sender's business (T3's fan-out); the
        # validator does not refuse a list that repeats an address.
        validate-envelope (sample-envelope "inbox" | update to ["a" "a" "b"])
    })

    # ------------------------------------------------------------- created
    (run-case "schema/rejects-a-created-that-does-not-parse-as-a-timestamp" {
        assert-rejects { validate-envelope (sample-envelope "inbox" | update created "not-a-date") } "created" "an unparseable timestamp must be named"
    })
    (run-case "schema/created-is-real-utc-not-local-time-wearing-a-Z" {
        # `created` ended in Z while carrying LOCAL wall clock, so every
        # envelope was off by the machine's UTC offset. Ordering still looked
        # right on one host — legacy-bus-pending sorts these — and would invert the
        # moment two hosts in different zones wrote to the same run. A
        # timestamp that lies about its zone is worse than none.
        let root = (make-runtime "utc")
        with-runtime $root {
            bus-identity "a" --run "r1" --identity {
                role: "impl", cwd: $nu.temp-dir, branch: "wk-t.0"
                session: "sid-a", skill: "wk-build", window: "impl-a@dotfiles"
            }
            let written = (legacy-inbox-send "a" --run "r1" --payload {stage: "doc-plan", instructions: "go", artifacts: []})

            # Parsed as UTC because of the Z, then compared with real UTC now.
            let stamped = ($written.created | into datetime)
            let skew = ((date now) - $stamped | into int | math abs)
            # Within a minute if the zone is right; an hour or more if not.
            assert-true ($skew < 60_000_000_000) $"created is ($written.created), which is ($skew / 1_000_000_000) seconds from now — check the timezone"
        }
        rm -rf $root
    })

    # ------------------------------------------------------------ content cap
    (run-case "schema/accepts-content-at-exactly-64-KiB" {
        # Off-by-one guard: the cap is inclusive, and it is measured on
        # content alone. Wrapping content this size in the envelope's own
        # {protocol, from, to, created, ...} JSON pushes the WHOLE envelope
        # past 64 KiB, so this only passes if the cap is checked against
        # content specifically rather than the serialized envelope.
        validate-envelope (sample-envelope "inbox" | update content (filler 65536))
    })
    (run-case "schema/rejects-content-one-byte-over-64-KiB" {
        assert-rejects {
            validate-envelope (sample-envelope "inbox" | update content (filler 65537))
        } "65537" "the refusal must name the exact byte count"
    })
    (run-case "schema/the-cap-is-bytes-not-characters" {
        # Each "é" is two UTF-8 bytes but one character. 40000 of them is
        # 40000 characters (well under any character-based cap) but 80000
        # bytes (over the 64 KiB byte cap) — a validator counting characters
        # instead of bytes would wrongly accept this.
        let multibyte = (0..<40000 | each {|_| "é" } | str join "")
        assert-eq ($multibyte | str length --grapheme-clusters) 40000 "sanity: 40000 characters"
        assert-rejects {
            validate-envelope (sample-envelope "inbox" | update content $multibyte)
        } "80000" "the cap counts bytes, and 40000 two-byte characters is 80000 of them"
    })

    # -------------------------------------------------- retired shape checks
    #
    # sp029 T2: a bus that cannot interpret `content` cannot gate its shape.
    # The stage/ticket/instructions contract that used to live in the
    # validator moved to the consumer (ft013); what used to be three
    # rejection cases here is now one acceptance, proving the shape is no
    # longer enforced at this layer.
    (run-case "schema/no-longer-gates-on-stage-or-ticket-shape" {
        validate-envelope (
            sample-envelope "inbox"
            | update content {stage: "wk-build", task: "t", design: "copied prose — legal now, opaque to the bus"}
        )
    })

    # ------------------------------------------------- result payload contract
    #
    # sp029 T2 does not touch what a `result` kind requires (sp029 T5 moves it
    # onto `content` as an ordinary message); these are unchanged from the v1
    # suite, just run against a v2 envelope.
    (run-case "schema/rejects-result-without-resume-command" {
        assert-rejects {
            validate-envelope (sample-envelope "result" | reject payload.resume)
        } "resume" "a result must carry its exact resume command"
    })
    (run-case "schema/rejects-unknown-result-status" {
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.status "finished")
        } "status" "an unknown result status must be rejected"
    })
    (run-case "schema/rejects-result-claiming-accepted" {
        # `accepted` is the initiator's verdict, never the worker's claim.
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.status "accepted")
        } "accepted" "a worker must not accept its own work"
    })
    (run-case "schema/rejects-result-claiming-unknown" {
        # adr0017: `unknown` is an observation, never a reported outcome.
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.status "unknown")
        } "unknown" "unknown is observational and cannot be reported as a result"
    })
    (run-case "schema/accepts-blocked-result-without-verdict" {
        # Only `complete` needs a verdict; a blocked worker reports why.
        validate-envelope (
            sample-envelope "result"
            | update payload.status "blocked"
            | update payload.validation null
        )
    })
    (run-case "schema/rejects-oversized-summary" {
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.summary (filler 5000))
        } "4 KiB" "summary cap must be enforced and named"
    })
    (run-case "schema/accepts-summary-at-the-cap" {
        validate-envelope (sample-envelope "result" | update payload.summary (filler 4096))
    })
    (run-case "schema/rejects-oversized-summary-naming-the-exact-byte-count" {
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.summary (filler 4097))
        } "4097" "the refusal must name the exact byte count, not just the cap"
    })

    # ------------------------------------------ sp029 T5: the narrowed result
    (run-case "schema/rejects-complete-with-null-validation" {
        # adr0027: completion is never inferred from prose. A 'complete'
        # result must carry its own typed verdict.
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.status "complete" | update payload.validation null)
        } "validation" "the refusal must name the missing field"
    })
    (run-case "schema/rejects-complete-with-empty-string-validation" {
        # Empty is refused exactly as strictly as null — a validator that
        # only checked for null would let "" pass as a real answer.
        assert-rejects {
            validate-envelope (sample-envelope "result" | update payload.status "complete" | update payload.validation "")
        } "validation" "an empty string must be refused, not treated as present"
    })
    (run-case "schema/accepts-complete-with-a-non-empty-validation" {
        validate-envelope (sample-envelope "result" | update payload.status "complete" | update payload.validation "PASS")
    })
    (run-case "schema/window-is-no-longer-required-on-a-result" {
        # The narrowed field set is status/validation/summary/session/resume
        # (## solution: "The typed result survives, narrowed") — window was
        # the legacy display concept and nothing reads it off a result
        # payload any more.
        validate-envelope (sample-envelope "result" | reject payload.window)
    })

    # ---------------------------------------------------------- message ids
    (run-case "msgid/is-26-characters" {
        let id = (mint-msg-id)
        assert-eq ($id | str length) $MSG_ID_CHARS $"expected ($MSG_ID_CHARS) characters, got ($id | str length)"
    })
    (run-case "msgid/10000-sequential-mints-sort-in-mint-order" {
        mut ids = []
        for i in 1..10_000 { $ids = ($ids | append (mint-msg-id)) }
        assert-eq ($ids | sort) $ids "10,000 sequential mints must already be in increasing order"
        assert-eq ($ids | uniq | length) 10_000 "and every one of them distinct"
    })
    (run-case "msgid/a-clock-that-steps-backward-still-mints-uniquely" {
        # Force the process's own bookkeeping far into the future, then mint
        # again: the timestamp must not go backward (best-effort ordering),
        # and the id must still be unique and greater than what came before.
        $env.PI_WORKER_LAST_MSG_TS = "99999999999999"
        $env.PI_WORKER_LAST_MSG_RAND = "0000000000000000"
        let after_jump = (mint-msg-id)
        let next = (mint-msg-id)
        assert-true ($next > $after_jump) "still strictly increasing across the simulated regression"
        $env.PI_WORKER_LAST_MSG_TS = "-1"
        $env.PI_WORKER_LAST_MSG_RAND = ""
    })
    (run-case "msgid/four-concurrent-processes-mint-10000-distinct-ids" {
        let root = (make-runtime "msgid-concurrency")
        let script = ($root | path join "mint-many.nu")
        let body = ('use ' + (worker-script $env.FILE_PWD) + ' *
let n = ($env.PIW_MINT_N | into int)
1..$n | each {|_| mint-msg-id } | str join "\n" | save -f $env.PIW_MINT_OUT')
        $body | save -f $script

        let outs = (1..4 | each {|i| $root | path join $"out-($i).txt" })
        let procs = ($outs | par-each {|out|
            with-env {PIW_MINT_N: "2500", PIW_MINT_OUT: $out} {
                ^$nu.current-exe $script | complete
            }
        })
        for p in $procs { assert-eq $p.exit_code 0 $"mint-many failed: ($p.stderr)" }

        let all = ($outs | each {|o| open $o | lines } | flatten)
        assert-eq ($all | length) 10_000 "every process minted its share"
        assert-eq ($all | uniq | length) 10_000 "no id was minted twice across processes"
        rm -rf $root
    })
]

$cases | to json
