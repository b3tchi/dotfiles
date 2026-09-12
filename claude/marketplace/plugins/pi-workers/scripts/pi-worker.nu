#!/usr/bin/env nu
# pi-worker — a message bus for visible Pi workers.
#
# Transport only. Flow lives in what agents say to each other, not in the
# transport (sp029 T8): the stage registry that used to gate a message's shape
# and a worker's placement by stage NAME retired. The one property it bought —
# nothing lands in the operator's shared tree without that being typed — is
# now a required `spawn --isolation worktree|main`, with no default.
#
# This file currently carries the PROTOCOL only: envelope schemas, the caps,
# and the worker state machine. The commands that move bytes (`spawn`, `send`,
# `wait`, `ack`, `status`, `inspect`, `resume`, `accept`, `stop`) land in
# sp028 T2-T4 on top of these definitions. Keeping the contract in one place
# and validating BEFORE any IO is the point: a malformed envelope must never
# reach a runtime directory, and an illegal state edge must never be persisted.
#
# Nushell per adr0001/adr0002 — this is workflow tooling handling structured
# data, and the compiled-helper path is explicitly excluded by sp028.
#
# TRANSPORT BOUNDARY — read this before adding a command.
#
# tmux hosts and displays worker processes. It is NOT the bus. Nothing here
# may use `tmux send-keys`, `tmux wait-for`, pane options, or `display-message`
# to carry a message, a completion signal, a status, or any coordination state.
# Those verbs put orchestration state in a place that cannot be versioned,
# sequenced, addressed, or replayed after a crash, and `send-keys` in
# particular types text into whatever now occupies a stale target — a shell,
# somebody else's editor. Messages travel as envelopes under
# $XDG_RUNTIME_DIR/pi-worker/<run-id>/<worker-uid>/ and nowhere else.
# The only legitimate tmux calls are window/process lifecycle: new-window,
# list-windows, kill-window.

# ------------------------------------------------------------------ constants

# The only two legal placements for a worker, and the whole of what survives
# the stage registry's retirement (sp029 T8): nothing lands in the operator's
# shared tree without the caller typing this, in full, every time.
export const ISOLATIONS = ["worktree" "main"]

# Bumped only for an incompatible envelope change. A reader that meets an
# unknown version fails closed rather than guessing at the fields.
#
# 1 -> 2 (sp029 T2): the envelope becomes peer-addressed. `from`/`to`/`content`
# join the schema; `sequence`/`run`/`uid`/`payload` stay on the wire for the
# v1 pipeline (legacy-inbox-send/bus-result/bus-settled/identity, all still
# `claim-slot`-based) but are no longer part of what a v2 reader requires. T3
# gives `send` its own project/queue-addressed path (`bus-send`, `queue-append`)
# alongside this legacy one; T9 moved the `main send`/`main wait` CLI verbs
# onto it (`--as`/`--to`, no `--run`), but `worker-resume`'s own inbox write
# still calls `legacy-inbox-send` directly — that is a task-instruction path
# to a worker's OWN inbox, not the peer bus, and out of scope for the CLI
# rewire. `claim-slot` itself does not retire here: dotfiles-v1zt tracks the
# four sites (`legacy-inbox-send`, `bus-result`, `bus-settled`'s error path,
# `bus-identity`) still pinning it, none of which this task's file scope
# touches. No migration: the bus lives in $XDG_RUNTIME_DIR, so the bump costs
# at most an in-flight project thread.
export const PROTOCOL_VERSION = 2

# Envelope cap: a bus message is an address plus a pointer, never a payload of
# record. Anything approaching this size means prose is being copied that
# belongs in the consumer's own stores.
export const MAX_ENVELOPE_BYTES = 65536

# Summary cap: what the initiator reads inline. Detail stays in the visible
# worker window and the Pi JSONL.
export const MAX_SUMMARY_BYTES = 4096

export const ENVELOPE_KINDS = ["inbox" "result" "error" "identity"]

# Persisted worker states.
export const WORKER_STATES = [
    "created"
    "running"
    "waiting_human"
    "blocked"
    "failed"
    "complete"
    "protocol_error"
    "accepted"
    "stopped"
]

# `unknown` is an OBSERVATIONAL verdict — "the evidence does not say" — and is
# deliberately absent from WORKER_STATES. Per adr0017 it must never be
# persisted, reported by a worker, or used to license cleanup: missing process,
# bus, or transcript evidence is a reason to look again, not to delete.
export const OBSERVATIONAL_VERDICTS = ["unknown" "gone"]

# A subject is worn as a tmux window name and a git branch name, so it is an
# address rather than a description. Long enough to be meaningful, short enough
# that `impl-<subject>@<project>` still reads in a window list.
export const MAX_SUBJECT_CHARS = 40

# An ADDRESS is worn as a file name, not merely read: the queue `bus-send`
# appends to is `queue/<address>` and nothing else (`queue-path`), and a
# claimed address is also a directory of its own under the project
# (`claim-address`, `worker-dir`). The hard boundary is therefore the
# filesystem's NAME_MAX, measured at 255 bytes here — 255 creates, 256 fails
# ENAMETOOLONG.
#
# The cap is set well below that boundary rather than at it. Every address
# this system mints is `<role>-<n>` or `r<n>` (`mint-uid`, `next-run-id`), so
# 64 is already far more than anything real ever needs, and the ~190 bytes of
# headroom mean a future name that composes an address with a suffix — the
# `<name>.marker` and `<sequence>.json` shapes already used beside it — cannot
# reach NAME_MAX either. A cap AT 255 would have to be revisited the first
# time anything is appended to an address.
#
# Characters, not bytes, and the two are the same count on purpose: the guard
# beside this one admits only `[A-Za-z0-9._-]`, all single-byte.
export const MAX_ADDRESS_CHARS = 64

# Statuses a worker may report in a result envelope. `accepted` is the
# initiator's verdict on the work and `stopped` is an external act, so neither
# is something a worker can claim about itself.
export const RESULT_STATUSES = ["complete" "waiting_human" "blocked" "failed"]

# A stage whose payload is "ticket" carries only an address: its message may
# name the stage and one ticket id and nothing else. The worker resolves the
# work itself from that id, so prose here would be a second source of truth
# that drifts from the first the moment either is edited.

# Fields that betray a copied task body in a work-stage payload.
const WORK_PAYLOAD_ALLOWED = ["stage" "task"]

# v2: addressing (`from`/`to`) and opaque `content` replace `sequence`/`run`/
# `uid`/`payload` as what a reader is guaranteed. The legacy fields still ride
# along on every envelope the v1 pipeline writes (legacy-inbox-send, bus-result,
# ..., pending T5/T6) for their own bookkeeping, but a v2 validator no longer
# requires them.
const ENVELOPE_REQUIRED = ["protocol" "kind" "from" "to" "created" "content"]

# ------------------------------------------------------------ state machine

# The legal edges, exhaustively. Anything not listed here is illegal, so the
# table is the contract rather than a hint: a new state cannot be smuggled in
# by an `if` somewhere in the IO layer.
#
# Shape notes:
#   - `created` may only start or be torn down; it never reports an outcome.
#   - every outcome state may resume to `running` EXCEPT `accepted`, which is
#     the end of the line, and `stopped`, which was an explicit teardown.
#   - `complete → accepted` is the only edge into `accepted`. That is what
#     makes acceptance mean "a human or a successful merge said so" instead of
#     "the worker said it was done".
export def transitions []: nothing -> table<from: string, to: string> {
    [
        [from, to];

        ["created", "running"]
        ["created", "stopped"]
        ["created", "protocol_error"]

        ["running", "waiting_human"]
        ["running", "blocked"]
        ["running", "failed"]
        ["running", "complete"]
        ["running", "protocol_error"]
        ["running", "stopped"]

        ["waiting_human", "running"]
        ["waiting_human", "failed"]
        ["waiting_human", "protocol_error"]
        ["waiting_human", "stopped"]

        ["blocked", "running"]
        ["blocked", "failed"]
        ["blocked", "protocol_error"]
        ["blocked", "stopped"]

        ["failed", "running"]
        ["failed", "stopped"]

        ["complete", "accepted"]
        ["complete", "running"]
        ["complete", "stopped"]

        ["protocol_error", "running"]
        ["protocol_error", "stopped"]
    ]
}

export def legal-transition? [from: string, to: string]: nothing -> bool {
    (transitions | where from == $from and to == $to | length) > 0
}

# Reject an illegal edge with a reason naming both ends. Fails closed: an
# unrecognised state is rejected before the pair is even considered, so a typo
# cannot silently behave like a fresh state with no edges.
export def validate-transition [from: string, to: string] {
    for state in [$from $to] {
        if $state in $OBSERVATIONAL_VERDICTS {
            error make {msg: $"'($state)' is an observational verdict, not a persisted state: it can never be a transition endpoint \(adr0017)"}
        }
        if $state not-in $WORKER_STATES {
            error make {msg: $"unknown worker state '($state)': not one of ($WORKER_STATES | str join ', ')"}
        }
    }
    if not (legal-transition? $from $to) {
        error make {msg: $"illegal transition ($from) -> ($to)"}
    }
}

# ------------------------------------------------------------- envelope size

# Size is measured on the serialized form, because that is what the cap is
# protecting: the bytes actually written to the runtime directory and read
# back by an initiator.
export def envelope-bytes [envelope: record]: nothing -> int {
    $envelope | to json --raw | into binary | bytes length
}

def text-bytes [value: string]: nothing -> int {
    $value | into binary | bytes length
}

# Byte size of a message's content specifically, not the enclosing envelope. A
# 64 KiB content field wrapped in {protocol, from, to, created, ...} JSON is
# already over 64 KiB total, so the cap this protects has to be measured on
# content alone — otherwise the boundary at exactly 64 KiB would be refused
# for the wrapper's overhead, not for anything the sender actually wrote.
def content-bytes [content: any]: nothing -> int {
    if ($content | describe) == "string" {
        text-bytes $content
    } else {
        $content | to json --raw | into binary | bytes length
    }
}

# ------------------------------------------------------------- message ids
#
# sp029 T2: a message id is a sortable timestamp plus a random suffix, not a
# claimed slot. Concurrent posters never contend, because nothing is shared —
# each id is minted independently and the fan-out that will use it (T3) has no
# `link(2)` race to lose.
#
# Shape is ULID-like: 10 Crockford-base32 characters encode a monotonic
# millisecond timestamp (26 chars total with the 16-character random tail),
# and Crockford's alphabet is itself ASCII-ascending, so two fixed-width ids
# compare correctly with plain string `<`/`sort` — no decoding required.
export const MSG_ID_CHARS = 26
const CROCKFORD_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const CROCKFORD_TS_WIDTH = 10
const CROCKFORD_RAND_WIDTH = 16

def crockford-chars []: nothing -> list<string> {
    $CROCKFORD_ALPHABET | split chars
}

# Encode a non-negative integer as fixed-width Crockford base32, zero-padded
# on the left so equal-width encodings sort the same way their integers do.
def crockford-encode [n: int, width: int]: nothing -> string {
    let chars = (crockford-chars)
    mut value = $n
    mut digits = []
    if $value == 0 {
        $digits = [0]
    } else {
        while $value > 0 {
            $digits = ([($value mod 32)] | append $digits)
            $value = ($value // 32)
        }
    }
    let s = ($digits | each {|d| $chars | get $d } | str join "")
    let pad = ($width - ($s | str length))
    if $pad > 0 {
        (0..<$pad | each {|_| "0" } | str join "") + $s
    } else {
        $s
    }
}

def crockford-random [width: int]: nothing -> string {
    let chars = (crockford-chars)
    (0..<$width) | each {|_| $chars | get (random int 0..31) } | str join ""
}

# Add 1 to a Crockford string, treated as big-endian base32 digits. Used to
# keep ids strictly increasing when two mints land in the same millisecond.
#
# A carry past the leftmost digit is dropped rather than widening the string:
# it needs the timestamp component to also be exhausted (2^80 mints in one
# millisecond), which is not a case that occurs. Documented rather than
# handled, per the edge case this function exists for.
def crockford-increment [s: string]: nothing -> string {
    let chars = (crockford-chars)
    let digits = ($s | split chars | each {|c|
        $chars | enumerate | where {|it| $it.item == $c } | get 0.index
    })
    mut carry = 1
    mut result = []
    for d in ($digits | reverse) {
        let v = ($d + $carry)
        if $v >= 32 {
            $result = ([($v - 32)] | append $result)
            $carry = 1
        } else {
            $result = ([$v] | append $result)
            $carry = 0
        }
    }
    $result | each {|i| $chars | get $i } | str join ""
}

# Mint a 26-character message id: monotonic within this process, unique
# across concurrent ones.
#
# `--env` is load-bearing: it is what lets the timestamp/random state persist
# from one call to the next WITHIN one nu process (env mutations made inside a
# `def --env` propagate back to the caller's scope), which is what makes
# 10,000 sequential mints come out strictly increasing regardless of clock
# resolution. Across processes there is no shared state at all — uniqueness
# there rests entirely on the 80 bits of randomness in the tail, which is
# enough that a collision among thousands of concurrent ids is not a
# practical concern.
#
# A clock that steps backwards is handled by clamping forward: the minted
# timestamp never drops below the last one this process minted, and the
# random tail increments instead of re-randomizing. Ids stay unique and
# non-decreasing even across a backward step; they simply stop tracking wall
# time exactly until it catches back up. That is the "ordering is best-effort"
# the design accepts — this function goes further and keeps it monotonic
# per-process, but no id anywhere promises a total order across processes.
export def --env mint-msg-id []: nothing -> string {
    let now_ms = (date now | format date "%s%3f" | into int)
    let last_ts = ($env | get -o PI_WORKER_LAST_MSG_TS | default "-1" | into int)
    let last_rand = ($env | get -o PI_WORKER_LAST_MSG_RAND | default "")

    let advancing = ($now_ms > $last_ts) or ($last_rand | is-empty)
    let ts = if $advancing { $now_ms } else { $last_ts }
    let rand = if $advancing { (crockford-random $CROCKFORD_RAND_WIDTH) } else { (crockford-increment $last_rand) }

    $env.PI_WORKER_LAST_MSG_TS = ($ts | into string)
    $env.PI_WORKER_LAST_MSG_RAND = $rand

    (crockford-encode $ts $CROCKFORD_TS_WIDTH) + $rand
}

# --------------------------------------------------------- payload contracts
#
# sp029 T8: the registry's own vocabulary — RESERVED_STAGES, `stages-taking`,
# stage names as transport words — retired with it. `resume` no longer sends
# a reserved "rejection" stage; it is an ordinary message (see `worker-resume`).

# sp029 T2: a message's content is opaque to the transport — "carries any
# consumer's vocabulary and interprets none of it". The stage/ticket/
# instructions shape that used to live here moved to the consumer (ft013):
# the bus no longer knows what a stage is, so the only thing left to check is
# the one thing the transport actually owns, the size cap. `--stored` is
# accepted and ignored: a v1 caller (read-box) still passes it, and a content
# size check has nothing to re-litigate against a registry that may have
# changed, so stored and fresh envelopes are checked identically now.
def validate-inbox-payload [content: any, --stored] {
    let size = (content-bytes $content)
    if $size > $MAX_ENVELOPE_BYTES {
        error make {msg: $"message content is ($size) bytes, over the 64 KiB cap: a bus message addresses work, it does not carry it"}
    }
}

def validate-result-payload [content: record] {
    # sp029 T5: `window` drops off the required list — the narrowed result
    # shape is status/validation/summary/session/resume (## solution: "The
    # typed result survives, narrowed"). Legacy callers may still set it as
    # an extra field; nothing here forbids that.
    let fields = ($content | columns)
    for required in ["status" "summary" "session" "resume"] {
        if $required not-in $fields {
            error make {msg: $"result payload must carry ($required)"}
        }
    }

    let status = $content.status
    if $status in $OBSERVATIONAL_VERDICTS {
        error make {msg: $"'($status)' is an observational verdict and can never be reported as a result status \(adr0017)"}
    }
    if $status == "accepted" {
        error make {msg: "a worker cannot report status 'accepted': acceptance is the initiator's verdict, granted only after a completion is reviewed or a merge succeeds"}
    }
    if $status not-in $RESULT_STATUSES {
        error make {msg: $"unknown result status '($status)': not one of ($RESULT_STATUSES | str join ', ')"}
    }

    # adr0027: completion is never inferred from prose. A `complete` result
    # must carry its own typed `validation` verdict, and an empty string is
    # refused exactly as strictly as null — checking only for null would let
    # "" pass as though it were a real answer. Not required for any other
    # status: `blocked`/`failed`/`waiting_human` are not verdicts adr0027
    # governs.
    if $status == "complete" and (($content | get -o validation) | is-empty) {
        error make {msg: "result status 'complete' must carry a non-null, non-empty 'validation' field (adr0027): completion is never inferred from prose"}
    }

    let summary_bytes = (text-bytes $content.summary)
    if $summary_bytes > $MAX_SUMMARY_BYTES {
        error make {msg: $"result summary is ($summary_bytes) bytes, over the 4 KiB summary cap; detail belongs in the worker window and the Pi transcript, not the envelope"}
    }
}

# Identity ties a worker UID to where it runs, what resumes it, and where it is
# visible. Every field is required: an identity missing its cwd or session is
# exactly the record that cannot be acted on later.
def validate-identity [payload: record] {
    for required in ["role" "cwd" "branch" "session" "skill" "window"] {
        if $required not-in ($payload | columns) {
            error make {msg: $"identity payload must carry ($required)"}
        }
        if ($payload | get $required | is-empty) {
            error make {msg: $"identity payload field '($required)' must not be empty"}
        }
    }
}

def validate-error-payload [payload: record] {
    for required in ["code" "detail"] {
        if $required not-in ($payload | columns) {
            error make {msg: $"error payload must carry ($required)"}
        }
    }
}

# ------------------------------------------------------------- envelope gate

# The single gate every envelope passes before it is written or acted on.
# Rejections name the offending field so an operator reading a log knows what
# to fix without reverse-engineering the validator.
export def validate-envelope [envelope: record, --stored] {
    let fields = ($envelope | columns)

    for required in $ENVELOPE_REQUIRED {
        if $required not-in $fields {
            error make {msg: $"envelope is missing required field '($required)'"}
        }
    }

    if $envelope.protocol != $PROTOCOL_VERSION {
        error make {msg: $"unknown protocol version ($envelope.protocol): this build speaks version ($PROTOCOL_VERSION) only"}
    }

    if $envelope.kind not-in $ENVELOPE_KINDS {
        error make {msg: $"unknown envelope kind '($envelope.kind)': not one of ($ENVELOPE_KINDS | str join ', ')"}
    }

    if ($envelope.from | describe) != "string" or ($envelope.from | is-empty) {
        error make {msg: "envelope field 'from' must be a non-empty address"}
    }

    # `to` is a list of at least one address. Duplicates (including the
    # sender addressing itself) are legal — fan-out (T3) dedupes rather than
    # refusing, since re-sending to an address already in the list is a
    # sender mistake worth ignoring, not a protocol violation.
    if not ($envelope.to | describe | str starts-with "list") {
        error make {msg: "envelope field 'to' must be a list of addresses"}
    }
    if ($envelope.to | is-empty) {
        error make {msg: "envelope field 'to' must name at least one address"}
    }
    if ($envelope.to | any {|addr| ($addr | describe) != "string" or ($addr | is-empty) }) {
        error make {msg: "envelope field 'to' must contain only non-empty addresses"}
    }

    if ($envelope.created | is-empty) {
        error make {msg: "envelope field 'created' must not be empty"}
    }
    if not (try { $envelope.created | into datetime; true } catch { false }) {
        error make {msg: $"envelope field 'created' must be an ISO timestamp, got '($envelope.created)'"}
    }

    match $envelope.kind {
        "inbox" => { validate-inbox-payload $envelope.content --stored=$stored }
        "result" => { validate-result-payload $envelope.payload }
        "error" => { validate-error-payload $envelope.payload }
        "identity" => { validate-identity $envelope.payload }
    }
}

# A worker whose agent settled without calling the typed result tool has NOT
# completed — there is no verdict, no summary, no resume evidence, only an idle
# prompt. Inferring success from an idle pane or an exited process is the
# failure this envelope exists to prevent, so the absence of a result is itself
# reported, as a protocol error.
export def settled-without-result [run: string, uid: string, sequence: int, created: string]: nothing -> record {
    let payload = {
        code: "protocol_error"
        detail: "agent settled without calling the typed result tool; completion is never inferred from an idle prompt, an exited pane, or assistant prose"
    }
    {
        protocol: $PROTOCOL_VERSION
        sequence: $sequence
        run: $run
        uid: $uid
        kind: "error"
        created: $created
        from: $uid
        to: [$run]
        content: $payload
        payload: $payload
    }
}

# ============================================================== message bus
#
# Layout, one directory per addressee:
#
#   $XDG_RUNTIME_DIR/pi-worker/<run-id>/<worker-uid>/
#       inbox/<sequence>.json     messages to the worker
#       outbox/<sequence>.json    results from the worker
#       outbox/<sequence>.ack     delivery receipt, written by the initiator
#
# Addressing is the directory path, which is what makes cross-run isolation
# structural rather than a filter someone can forget: a reader scoped to
# run-1 cannot form a path into run-2.
#
# Two durability rules hold everything together:
#
#   1. Every envelope is written to a scratch name and renamed into place.
#      rename(2) is atomic, so a reader sees the whole envelope or no file at
#      all. An interrupted write leaves a `.tmp.` file, which no reader looks
#      at.
#   2. A sequence slot is claimed with link(2), which fails if the target
#      exists. Two writers racing for the same slot cannot both win, so the
#      loser retries instead of silently overwriting the winner.
#
# `wait` is deliberately non-destructive: it reports the oldest unacknowledged
# result and leaves it in place. Only `ack` marks it delivered, so an initiator
# that dies between reading and acknowledging sees the same result again.
# Acknowledgement is a delivery receipt and nothing more — it never means the
# work was accepted.

const BUS_DIRNAME = "pi-worker"

# The bus owns the branches it creates, so it owns their namespace. A worker
# branch is throwaway and must never collide with one a human made.
const BRANCH_PREFIX = "wk-"
const MAX_SEQUENCE_ATTEMPTS = 64

# Root of the LEGACY bus tree: one flat $XDG_RUNTIME_DIR/pi-worker directory
# shared by every project, addressed through a minted `run` id. Every verb
# still built on `run-dir`/`worker-dir` (send, wait, result, status, ...)
# reads and writes here until T2-T4 rewrite them onto `project-dir` below —
# changing what THIS returns would silently break all of them, which sp029 T1
# is not scoped to do. New code should prefer `project-dir`.
export def bus-root []: nothing -> string {
    let base = ($env | get -o XDG_RUNTIME_DIR | default "")
    if ($base | is-empty) {
        error make {msg: "XDG_RUNTIME_DIR is unset: the worker bus has no runtime directory to address"}
    }
    $base | path join $BUS_DIRNAME
}

def run-dir [run: string]: nothing -> string { bus-root | path join $run }
def worker-dir [run: string, uid: string]: nothing -> string { run-dir $run | path join $uid }

# Refuse a bus tree we do not own or that others can read.
#
# $XDG_RUNTIME_DIR is normally private, but it is not guaranteed to be, and a
# bus tree planted under a world-writable path by someone else would otherwise
# be used as if it were ours. Envelopes carry task ids, session ids and resume
# commands; they are not for other users.
export def bus-assert-owned [dir: string] {
    if not ($dir | path exists) {
        error make {msg: $"bus directory does not exist: ($dir)"}
    }
    let owner = (^stat -c "%u" $dir | str trim | into int)
    let me = (^id -u | str trim | into int)
    if $owner != $me {
        error make {msg: $"refusing to use ($dir): owner uid ($owner) is not this user (($me))"}
    }
    let mode = (^stat -c "%a" $dir | str trim)
    if $mode != "700" {
        error make {msg: $"refusing to use ($dir): mode ($mode) is not 0700, so another user could read worker envelopes"}
    }
}

# Create a directory chain private to this user, verifying each level.
#
# `mkdir -m 700` rather than mkdir-then-chmod: the two-step version leaves the
# directory at the umask mode (0755 on a default umask) for a moment, and a
# concurrent writer that checks it in that window correctly refuses to use it.
# That is not theoretical — three racing writers hit it on the first run of the
# concurrency case. `-p` makes losing the create race a no-op instead of an
# error.
def ensure-dir [dir: string] {
    if not ($dir | path exists) {
        ^mkdir -m 700 -p $dir
    }
    bus-assert-owned $dir
}

def ensure-worker-dirs [run: string, uid: string] {
    ensure-dir (bus-root)
    ensure-dir (run-dir $run)
    ensure-dir (worker-dir $run $uid)
    for box in ["inbox" "outbox"] {
        ensure-dir (worker-dir $run $uid | path join $box)
    }
}

# -------------------------------------------------------------- project scoping (sp029 T1)

# A filesystem-safe, collision-resistant name for a repository path.
#
# A readable prefix alone is not enough: `/a/b` and `/a-b` must land in
# different projects, and a path separator and a literal hyphen both flatten
# to `-` under any naive sanitizer, so a prefix built only from allowed
# characters cannot tell them apart. The hash of the full normalized path
# carries the actual identity; the prefix exists only so a directory listing
# is legible to a human, and is never relied on for uniqueness.
def project-slug [path: string]: nothing -> string {
    let normalized = ($path | str trim --right --char "/")
    let normalized = if ($normalized | is-empty) { "/" } else { $normalized }
    let digest = ($normalized | hash sha256 | str substring 0..12)
    let readable = (
        $normalized
        | path basename
        | str replace --all --regex '[^A-Za-z0-9._]' "-"
    )
    let readable = if ($readable | is-empty) { "root" } else { $readable }
    $"($readable)-($digest)"
}

# The project's bus tree, keyed by a slug of the repo's MAIN worktree.
#
# Deliberately `main-worktree`, never a bare `current-repo`: a worker stands
# in a throwaway `wk-*` worktree, and slugging that path directly would make
# every worker its own project, which is the exact discovery failure this
# task exists to fix. Every agent working on the repo — from the main
# worktree or any `wk-*` of it — resolves to the same directory.
#
# Errors rather than falling back to anything when there is no project to
# resolve: a worker bus has no notion of a default project the way a shell
# has a default directory, and creating one under an arbitrary cwd would
# plant bus state nothing could find again. Pure lookup — never creates a
# directory; pair with `ensure-bus-dirs` to do that.
export def project-dir []: nothing -> string {
    let base = ($env | get -o XDG_RUNTIME_DIR | default "")
    if ($base | is-empty) {
        error make {msg: "XDG_RUNTIME_DIR is unset: the worker bus has no runtime directory to address"}
    }
    let repo = (current-repo)
    if ($repo | is-empty) {
        error make {msg: "not inside a git repository: the worker bus has no project to address"}
    }
    let slug = (project-slug (main-worktree $repo))
    $base | path join $BUS_DIRNAME $slug "bus"
}

# Create the project's flat message log and per-agent queue directory —
# `bus/messages` and `bus/queue`, siblings under `project-dir`. Unlike the
# legacy run/uid tree, nothing here is scoped to a worker address, so there
# is no id to thread through: T2-T4 populate these once envelopes and queue
# rows exist to put in them.
#
# One `ensure-dir` call PER LEVEL, exactly like `ensure-worker-dirs` above —
# not `ensure-dir (project-dir)` alone. `mkdir -m MODE -p` only applies MODE
# to the final path component; every ancestor `-p` creates along the way
# keeps the umask mode (0755 by default). Calling it once on the 3-level
# `pi-worker/<slug>/bus` path would leave `pi-worker/` and `pi-worker/<slug>/`
# world-readable — the slug, and so the repo's identity, visible to every
# local user — the moment either does not already exist, which is the normal
# case right after `$XDG_RUNTIME_DIR` is wiped at logout.
export def ensure-bus-dirs []: nothing -> nothing {
    let dir = (project-dir)
    let project_root = ($dir | path dirname)
    let pi_worker_root = ($project_root | path dirname)
    ensure-dir $pi_worker_root
    ensure-dir $project_root
    ensure-dir $dir
    ensure-dir ($dir | path join "messages")
    ensure-dir ($dir | path join "queue")
}

# ------------------------------------------------ durable placement (sp029 T6)
#
# A `wk-*` worktree outlives the login session that spawned it, while
# `$XDG_RUNTIME_DIR` is wiped at logout. If the only record of which worktree a
# worker holds lived there, an orphaned tree would become indistinguishable
# from an occupied one the moment a session ends — and `accept`/`reclaim`
# DELETE trees on that evidence. So the placement record (identity, plus the
# `accepted`/`stopped` verdicts granted from outside the worker) lives under
# `$XDG_STATE_HOME` instead, which is the adr0013 precedent applied here.
#
# `waiting_human` and `reopened` stay where they are (the legacy `run`/`uid`
# tree): they are not placement evidence — they are review-flow bookkeeping
# that `main resume`'s rejection counting still writes, and retiring THAT
# writer is sp029 T8's job, not this one's. Moving their storage now without
# also removing the writer would either duplicate the marker across two trees
# or break `main resume`'s own tests out from under a task that never touches
# `worker-resume`. See the comment on `state-markers` below.
export def state-root []: nothing -> string {
    let base = ($env | get -o XDG_STATE_HOME | default "")
    if ($base | is-not-empty) {
        return ($base | path join $BUS_DIRNAME)
    }
    # XDG's own fallback, not an invention: the basedir spec defines
    # `$HOME/.local/state` as what `$XDG_STATE_HOME` means when it is unset.
    let home = ($env | get -o HOME | default "")
    if ($home | is-empty) {
        error make {msg: "XDG_STATE_HOME is unset and HOME is unset: the worker placement record has no durable directory to address"}
    }
    $home | path join ".local" "state" $BUS_DIRNAME
}

# The SAME slug `project-dir` uses (`project-slug` of the main worktree), so
# the runtime bus and the durable placement record agree on which project a
# worker belongs to without a second implementation to drift out of step.
#
# Falls back to slugging `cwd` verbatim when it is not inside a real git
# repository. That is deliberate, not a workaround: plenty of existing bus
# fixtures (schema/protocol cases in particular) plant an identity at a
# throwaway path like `/tmp/nowhere` that was never meant to resolve to a
# repo, and `main-worktree` erroring there would make identity storage a
# harder requirement than identity itself (`validate-identity` only requires
# `cwd` to be non-empty, never that it exists). A real worktree still
# resolves through `main-worktree` and groups correctly with its siblings;
# an unresolvable one just gets an isolated bucket of its own, which is
# never asked to group with anything.
def resolve-project-slug [cwd: string]: nothing -> string {
    let resolved = (try { main-worktree $cwd } catch { "" })
    project-slug (if ($resolved | is-empty) { $cwd } else { $resolved })
}

# Nested one level deeper than the spec's own `agents/<uid>/` — `agents/<run>/
# <uid>/`. That nesting was load-bearing while a uid was only unique within
# its own run: two runs could hold a "w1" each, and collapsing `<uid>` to the
# project level would have filed both under one path, where one worker's
# `stopped` marker silently applied to the other.
#
# dotfiles-bg65 removed the premise rather than the nesting: a uid is now
# unique per PROJECT (`mint-uid`/`claim-address`), so the `<run>` level is
# vestigial — one uid can only ever appear under one run of it. It stays
# because every reader and writer here is `(run, uid)`-shaped and flattening
# them is a migration of stored state, not a rename; `project-uids` and
# `resolve-run` both simply search across the level rather than within it.
def agent-state-dir [slug: string, run: string, uid: string]: nothing -> string {
    state-root | path join $slug "agents" $run $uid
}

# One `ensure-dir` call per level, for the reason `ensure-bus-dirs` above
# documents: `mkdir -m -p` only applies the mode to the final path component,
# and every ancestor `-p` silently creates is left at the umask mode instead.
def ensure-state-dirs [slug: string, run: string, uid: string] {
    let root = (state-root)
    let project_dir = ($root | path join $slug)
    let agents_dir = ($project_dir | path join "agents")
    let run_dir = ($agents_dir | path join $run)
    let uid_dir = ($run_dir | path join $uid)
    ensure-dir $root
    ensure-dir $project_dir
    ensure-dir $agents_dir
    ensure-dir $run_dir
    ensure-dir $uid_dir
}

# `bus-identity`/marker readers have only `(run, uid)` in hand — every
# existing call site already addresses a worker that way, and none of them
# know its `cwd` up front, which is exactly what would be needed to
# recompute the slug above. So the slug is recorded once, at write time, in
# a tiny durable pointer keyed by the one thing every caller does have.
def agent-index-path [run: string, uid: string]: nothing -> string {
    state-root | path join ".index" $run $uid
}

def record-agent-slug [run: string, uid: string, slug: string] {
    let path = (agent-index-path $run $uid)
    ensure-dir ($path | path dirname)
    let scratch = ($path + $".tmp.(random chars --length 10)")
    $slug | save -f $scratch
    chmod 600 $scratch
    mv -f $scratch $path
}

# The project slug this (run, uid) was last recorded under, or null if it was
# never recorded — an unknown worker, never durably placed at all.
def resolve-agent-slug [run: string, uid: string]: nothing -> any {
    let path = (agent-index-path $run $uid)
    if not ($path | path exists) { return null }
    let slug = (open --raw $path | str trim)
    if ($slug | is-empty) { null } else { $slug }
}

# Where a worker's identity LOG lives, or null when it was never recorded.
# Kept as its own lookup (rather than folded into `bus-identity-envelope`)
# because `worker-timeline` needs the whole log — every re-record, not just
# the latest — and used to read it straight off the runtime tree before this
# task moved identity off it.
def identity-log-dir [run: string, uid: string]: nothing -> any {
    let slug = (resolve-agent-slug $run $uid)
    if $slug == null { return null }
    agent-state-dir $slug $run $uid | path join "identity"
}

# ------------------------------------------ project-wide addresses (dotfiles-bg65)
#
# A uid is an address on the PROJECT's bus: `bus/queue/<uid>` is one file per
# agent for the whole project, a message's `to` list names bare uids, and
# `resolve-run` answers a uid by searching one project's whole agents tree.
# Uniqueness therefore has to hold across the project — every run of it — and
# for a while it did not: `mint-uid` searched a single run's directory, which
# was a real namespace only while `--run` was a caller-supplied grouping that
# several workers shared. sp029 T9 retired `--run`, so every spawn now mints
# its own run and that directory is empty BY CONSTRUCTION — every ordinary
# spawn of a role minted `<role>-1`, forever. Two live workers then shared one
# queue, and `resolve-run` reached whichever run sorted first, leaving the
# other addressable by nothing but `rm -rf` (observed in the sp029 T11 smoke).
#
# The project's queue directory, for a path standing inside it.
#
# The tolerant sibling of `project-dir`: same slug, same directory, but it
# answers "" instead of raising when there is no runtime dir, because this is
# only ever consulted to widen a taken-address set. A project with no bus
# tree yet has no queues, which is the same answer an error would have to be
# turned into at every call site.
def project-queue-dir [base: string]: nothing -> string {
    queue-dir-of (resolve-project-slug $base)
}

# The same directory, for a caller that already holds the slug and must NOT
# re-derive it from a path. `worker-release` is that caller: `accept` deletes
# the worktree an identity names, and slugging a path that no longer exists
# answers with `resolve-project-slug`'s fallback bucket instead of the project
# the worker was actually filed under.
def queue-dir-of [slug: string]: nothing -> string {
    let root = ($env | get -o XDG_RUNTIME_DIR | default "")
    if ($root | is-empty) { return "" }
    $root | path join $BUS_DIRNAME $slug "bus" "queue"
}

# Where this project's claimed addresses live: one directory per uid.
#
# Under `state-root`, beside the placement record and for the same reason
# (sp029 T6): the runtime tree is wiped at logout while a worker's identity —
# and so its address — outlives the login session that spawned it. A claim
# whose only record was on the runtime bus would be forgotten by the next
# login, which is exactly when re-minting an address that still resolves does
# the most damage.
def address-dir [slug: string]: nothing -> string {
    state-root | path join $slug "addresses"
}

# Every uid this project can already address.
#
# The union of three sources, because each one holds addresses the others do
# not:
#
#   agents/<run>/<uid>   the durable placement record — what `resolve-run`
#                        answers a uid from, and so the authoritative set of
#                        addresses a CLI verb can reach.
#   addresses/<uid>      claims taken but not yet recorded: the window between
#                        minting an address and writing its identity, which is
#                        where two racing spawns used to both win.
#   bus/queue/<uid>      addresses live on the project bus with no placement
#                        record of their own — a session that claimed its own
#                        address (sp029 T7) is exactly that shape. Those ids
#                        are `self-<hex>` today and so cannot collide with a
#                        `<role>-<n>`, but minting around them costs one `ls`
#                        and does not depend on that staying true.
export def project-uids [repo: string = ""]: nothing -> list<string> {
    let base = (if ($repo | is-empty) { current-repo } else { $repo })
    let slug = (resolve-project-slug $base)

    let agents = (state-root | path join $slug "agents")
    let placed = (if ($agents | path exists) {
        ls $agents | where type == dir | get name | each {|run_dir|
            ls $run_dir | where type == dir | get name | each {|d| $d | path basename }
        } | flatten
    } else { [] })

    let claims = (address-dir $slug)
    let claimed = (if ($claims | path exists) {
        ls $claims | get name | each {|d| $d | path basename }
    } else { [] })

    let queues = (project-queue-dir $base)
    let queued = (if ($queues | is-not-empty) and ($queues | path exists) {
        ls $queues | get name | each {|f| $f | path basename }
    } else { [] })

    $placed | append $claimed | append $queued | uniq
}

# Take `uid` as this project's address, or refuse because someone else has it.
#
# Two steps, and the order matters. The `project-uids` check is what produces
# a refusal an operator can act on — it names the address and says where it is
# already known. The `mkdir` is what makes the claim SAFE: without `-p` it
# fails when the directory exists, so it is one atomic create rather than a
# check followed by a create, and two spawns racing for the same lowest-free
# uid cannot both win it. That is the same reasoning `claim-slot` applies to a
# sequence slot with link(2); `ensure-dir`'s `mkdir -p` is deliberately the
# opposite (losing a create race there is a no-op, not an answer).
export def claim-address [repo: string, uid: string]: nothing -> nothing {
    let base = (if ($repo | is-empty) { current-repo } else { $repo })
    let slug = (resolve-project-slug $base)
    if $uid in (project-uids $base) {
        error make {msg: $"($uid) is already an address in this project: spawning onto it would put two workers on one queue, where only one of them could ever be reached by uid. Use a different uid, or release this one with `rm --uid ($uid)` once it is finished with"}
    }
    let dir = (address-dir $slug)
    ensure-dir (state-root)
    ensure-dir (state-root | path join $slug)
    ensure-dir $dir
    # NOT `ensure-dir`: `-p` would make an occupied address look free.
    let made = (do { ^mkdir -m 700 ($dir | path join $uid) } | complete)
    if $made.exit_code != 0 {
        error make {msg: $"($uid) is already an address in this project: another spawn claimed it first. Use a different uid, or release this one with `rm --uid ($uid)`"}
    }
}

# Let go of a claimed address. Idempotent: releasing one nobody holds is not
# an error, because both callers (a spawn that failed after claiming, and
# `rm`) are cleaning up rather than asserting.
export def release-address [repo: string, uid: string]: nothing -> nothing {
    let base = (if ($repo | is-empty) { current-repo } else { $repo })
    release-address-at (resolve-project-slug $base) $uid
}

# By slug, for the caller that already has one — see `queue-dir-of`.
def release-address-at [slug: string, uid: string]: nothing -> nothing {
    let dir = (address-dir $slug | path join $uid)
    if ($dir | path exists) { rm -rf $dir }
}

# ------------------------------------------------------ presence (sp030 T3)
#
# The worker's own evidence about its own state ([[adr0017]]: only a
# component's own evidence about itself may license anything, and here it
# licenses nothing at all — presence is read, never acted on). Published
# under the SAME directory `claim-address` mints, rather than a fresh
# `agents/<run>/<uid>/` bucket of its own: `release-address`'s `rm -rf` on
# that directory is then ALSO the presence cleanup, so a released uid can
# never carry a stale presence file nobody remembers to prune.
#
# Exactly because presence lives there, `presence-write` must never CREATE
# that directory — doing so would let a call for a released or never-claimed
# uid conjure the very claim it is supposed to find already made, resurrecting
# an address nothing else has taken. It refuses instead, the same way any
# other verb here refuses to act on an address it does not recognise.
def presence-dir [slug: string, uid: string]: nothing -> string {
    address-dir $slug | path join $uid
}

def presence-path [slug: string, uid: string]: nothing -> string {
    presence-dir $slug $uid | path join "presence"
}

# How stale a reported state may be before `main workers` stops trusting it
# and reports `unknown` in its place.
#
# There is no periodic heartbeat here (sp030's `## known_limitations`): the
# extension (Task 4) writes only on a lifecycle TRANSITION, so a worker
# sitting in one state — mid-turn, streaming a long tool call — is silent by
# design for as long as that turn takes, and that silence must not itself
# read as staleness. 90s is chosen against that shape: comfortably longer
# than the gap between two ordinary transitions in an active turn, while
# still short enough to flag a worker whose extension crashed or whose window
# died before `session_shutdown` ever fired. adr0017's own warning applies
# either way this number is missed: a beat that never comes and a beat that
# came 91s ago are deliberately indistinguishable from here — both read
# `unknown`, and `unknown` licenses nothing. Task 4 records the measured
# per-transition cost; if that cost forces debouncing, this bound is the
# first knob to revisit, not the debounce interval.
const PRESENCE_FRESH_SECS = 90

# The raw stored record, or a sentinel — never a raise. Three outcomes, and
# they are deliberately NOT the same shape: `null` means no worker has ever
# published here (an ordinary, common case — most roles are never spawned),
# while the literal string `"unknown"` means a file exists but could not be
# trusted (truncated write, foreign JSON shape, missing fields). Collapsing
# both to `null` would make `main workers` unable to tell "empty" from
# "unknown" apart, which is exactly the distinction its `presence` column
# has to draw.
def presence-read-at [slug: string, uid: string]: nothing -> any {
    let path = (presence-path $slug $uid)
    if not ($path | path exists) { return null }
    let raw = (open --raw $path)
    let parsed = (try { $raw | from json } catch { null })
    if $parsed == null { return "unknown" }
    # `from json` is lenient the same way `read-box` already documents: given
    # bare or partial text it can return a plain string instead of raising, so
    # the shape has to be checked explicitly rather than trusted.
    if not (($parsed | describe) | str starts-with "record") { return "unknown" }
    if not ("state" in ($parsed | columns)) or not ("at" in ($parsed | columns)) {
        return "unknown"
    }
    {state: $parsed.state, at: $parsed.at}
}

# `presence-write <uid> <state>` — the module function Task 4's extension
# shells out to exactly the way it already calls `queue-mark-read`: one
# `nu -c` per transition, run from inside the worker's own worktree so
# `--repo`'s cwd-derived default resolves the same project every other verb
# does.
#
# Scratch name then rename, mode `0600` before the link is visible — the same
# discipline `write-marker`/`record-agent-slug` already use for a single
# mutable file, not `claim-slot`'s exclusive `link(2)`: presence has exactly
# one writer (the worker about itself) and the latest transition is always
# the one that should win, so there is nothing here to arbitrate between.
# Concurrent writes from that one writer still resolve cleanly — a reader
# either opens the file before or after the `mv`, and `mv` on the same
# filesystem is atomic, so it never observes a half-written record.
export def presence-write [uid: string, state: string, --repo: string = ""]: nothing -> nothing {
    let base = (if ($repo | is-empty) { current-repo } else { $repo })
    let slug = (resolve-project-slug $base)
    let dir = (presence-dir $slug $uid)
    if not ($dir | path exists) {
        error make {msg: $"($uid) has no claimed address in this project: presence cannot be written for a worker that was never spawned, or one already released. Nothing was written"}
    }
    let scratch = ($dir | path join $".tmp.(random chars --length 10)")
    {state: $state, at: (now-stamp)} | to json | save -f $scratch
    chmod 600 $scratch
    mv -f $scratch (presence-path $slug $uid)
}

# `presence-read <uid>` — the record `{state, at}`, or `null` when the worker
# has never published (or was released before it did). Never raises: an
# unspawned or already-released uid is the ordinary case, not a failure.
export def presence-read [uid: string, --repo: string = ""]: nothing -> any {
    let base = (if ($repo | is-empty) { current-repo } else { $repo })
    presence-read-at (resolve-project-slug $base) $uid
}

# Where a worker's presence record lives on disk. Exported the same way
# `project-dir` is, purely so a case can locate the physical file to assert
# its mode or plant a corrupt one directly — it is never how `presence-write`/
# `presence-read` find their own path, which stays internal to this section.
export def presence-file [uid: string, --repo: string = ""]: nothing -> string {
    let base = (if ($repo | is-empty) { current-repo } else { $repo })
    presence-path (resolve-project-slug $base) $uid
}

# The value `main workers` renders in its `presence` column: the reported
# state when the reading is within `PRESENCE_FRESH_SECS`, `unknown` when it is
# older (a negative age — the clock moved backward — counts as older, never
# as fresh forever) or unparseable, empty when no presence file exists at
# all. `unknown` is returned as plain observational data; nothing here or in
# any verb branches on it to decide a worker is alive, stopped or reapable
# ([[adr0017]]).
def presence-column [slug: string, uid: string]: nothing -> string {
    let raw = (presence-read-at $slug $uid)
    if $raw == null {
        ""
    } else if ($raw | describe) == "string" {
        "unknown"
    } else {
        let age = (try { ((date now) - ($raw.at | into datetime)) / 1sec } catch { -1.0 })
        if $age < 0 { "unknown" } else if $age > $PRESENCE_FRESH_SECS { "unknown" } else { $raw.state }
    }
}

# Write `envelope` into `dir` at the next free sequence.
#
# The scratch file is created with the final mode BEFORE it is linked into
# place, so an envelope is never briefly readable by anyone else. link(2)
# claims the slot; if another writer got there first, the next sequence is
# tried. The scratch file is removed in both outcomes.
#
# sp029 T3: the peer-addressed send path (`bus-send`/`queue-append` below)
# does not use this — a message id is minted, not claimed, and there is no
# sequence to serialize. `claim-slot`/`next-sequence` survive only because
# `legacy-inbox-send`, `bus-result`, `bus-settled` and `bus-identity` still
# write run/uid-addressed, sequence-numbered envelopes pending T5 (result)
# and T6 (identity); they retire for real once those migrate onto
# `queue-append` (dotfiles-v1zt).
def claim-slot [dir: string, envelope: record] {
    let scratch = ($dir | path join $".tmp.(random chars --length 10)")

    mut seq = ((next-sequence $dir) - 1)
    mut attempts = 0
    loop {
        $seq = $seq + 1
        $attempts = $attempts + 1
        if $attempts > $MAX_SEQUENCE_ATTEMPTS {
            rm -f $scratch
            error make {msg: $"could not claim a sequence in ($dir) after ($MAX_SEQUENCE_ATTEMPTS) attempts"}
        }

        let sealed = ($envelope | update sequence $seq)
        validate-envelope $sealed
        $sealed | to json | save -f $scratch
        chmod 600 $scratch

        let target = ($dir | path join $"($seq).json")
        let linked = (do { ^ln $scratch $target } | complete)
        if $linked.exit_code == 0 {
            rm -f $scratch
            return $sealed
        }
        # Slot taken by a concurrent writer: try the next one.
    }
}

# Lowest unused sequence in a box. Sequences start at 1 so that a missing file
# and sequence zero can never be confused.
def next-sequence [dir: string]: nothing -> int {
    let used = (
        ls $dir
        | get name
        | where {|n| ($n | path basename | str ends-with ".json") }
        | each {|n| $n | path basename | str replace ".json" "" | into int }
    )
    if ($used | is-empty) { 1 } else { ($used | math max) + 1 }
}

# Read every envelope in a box, oldest first.
#
# Scratch files are skipped by name: an interrupted write leaves `.tmp.<rand>`,
# which is not a sequence file, so a partial envelope is structurally invisible
# rather than filtered out after parsing.
#
# A file that IS named like an envelope but does not parse or does not validate
# is an error, never a skip. Silently passing over it would let a completion
# disappear, which is strictly worse than stopping: the operator can fix a
# named file, but cannot notice a result that was never reported.
# NOTE ON THE LOOP: this is a `for` accumulating into a mut, not the `each`
# pipeline it visually wants to be. In nushell 0.115 an `error make` raised
# inside an `each` closure is SWALLOWED — the element is passed through and the
# pipeline completes as if nothing happened. Measured directly:
#
#   [1 2] | each {|x| if $x == 2 { error make {msg: "boom"} }; $x } | length
#   => 2      (no error surfaces)
#
# The same body inside `for` raises correctly. That difference is the whole
# reason this reads the way it does: with `each`, a corrupt envelope was
# delivered to the initiator as a bare string with no error anywhere — the
# exact silent-failure mode "fail closed" exists to prevent. Do not "simplify"
# this back into `each` without re-measuring that behavior.
def read-box [dir: string]: nothing -> list<record> {
    if not ($dir | path exists) { return [] }
    let files = (
        ls $dir
        | get name
        | where {|n| ($n | path basename | str ends-with ".json") }
        | sort-by {|n| $n | path basename | str replace ".json" "" | into int }
    )

    mut envelopes = []
    for n in $files {
        let raw = (open --raw $n)
        let parsed = (try { $raw | from json } catch {
            error make {msg: $"unparseable envelope ($n | path basename) in ($dir): the bus fails closed rather than skipping a message"}
        })
        # `from json` is lenient: given bare text it returns that text as a
        # string instead of raising, so the shape has to be checked explicitly.
        if not (($parsed | describe) | str starts-with "record") {
            error make {msg: $"unparseable envelope ($n | path basename) in ($dir): expected a JSON object, got ($parsed | describe)"}
        }
        # `--stored`: the structure is still checked, but the stage is not
        # re-resolved against a registry that may have changed since.
        try { validate-envelope $parsed --stored } catch {|e|
            error make {msg: $"invalid envelope ($n | path basename) in ($dir): ($e.msg)"}
        }
        $envelopes = ($envelopes | append $parsed)
    }
    $envelopes
}

# The `Z` means UTC, so the value has to BE UTC.
#
# Without `to-timezone UTC` this formatted local wall clock and labelled it Z,
# putting every envelope out by the machine's offset. Ordering still looked
# right on one host — legacy-bus-pending sorts on this field — and would invert the
# moment two hosts in different zones wrote into the same run. A timestamp that
# lies about its zone is worse than no timestamp.
def now-stamp []: nothing -> string {
    date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%S%.6fZ"
}

# sp029 T2 bridge: the v1 pipeline (legacy-inbox-send/bus-result/bus-settled/
# identity, all still `run`/`uid`-addressed) still calls this with a run and a
# worker uid, not a resolved peer list. It derives a v2-shaped `from`/`to`
# from the direction the kind already implies — `inbox` travels
# initiator-to-worker, everything else worker-to-initiator — so every
# envelope this module writes satisfies the v2 validator without every caller
# needing to know an address it cannot yet supply. `content` mirrors
# `payload`: T3's own peer-addressed `bus-send` (below) does not call this
# bridge at all — it builds a real `from`/`to`/`content` envelope directly —
# so the mirroring here still only serves the v1 callers.
#
# It survives past T5/T6/T9 landing, and NOT because retiring it is any one
# of their job — dotfiles-6nvx.19 named T5 for this, which was wrong: T5 (this
# module's `bus-result`/`bus-settled`) and T6 (`bus-identity`) both migrated
# their OUTPUT (a real peer message is now sent alongside), but their v1
# callers still exist and still call this bridge for the legacy outbox/inbox
# write underneath, and T9 (this task) did not touch that call graph either —
# CLI verbs move to new addressing, the internal v1 functions they used to
# call directly do not. This bridge retires only when `legacy-inbox-send`,
# `bus-result`, `bus-settled`'s error path and `bus-identity` — the same four
# sites dotfiles-v1zt already tracks for `claim-slot`/`next-sequence` — stop
# writing the v1 shape at all.
def envelope-for [run: string, uid: string, kind: string, payload: record]: nothing -> record {
    let addressing = if $kind == "inbox" { {from: $run, to: [$uid]} } else { {from: $uid, to: [$run]} }
    {
        protocol: $PROTOCOL_VERSION
        sequence: 0
        run: $run
        uid: $uid
        kind: $kind
        created: (now-stamp)
        from: $addressing.from
        to: $addressing.to
        content: $payload
        payload: $payload
    }
}

# --------------------------------------------------------------- commands

# Address a message to one worker's inbox.
#
# sp029 T3: this is the LEGACY, run/uid-addressed, `claim-slot`-based sender —
# two path regimes live in this module now. `worker-resume`'s rejection
# resend and the `main send` CLI verb still call it, both T8/T9 territory
# (flow vocabulary, CLI surface) and out of scope here, so it keeps its name
# and shape rather than being deleted out from under them. The real T3
# deliverable is `bus-send` below, addressed by `to`/`from` against the
# project-scoped bus rather than a run. This function, `claim-slot` and
# `next-sequence` retire together, tracked as dotfiles-v1zt, once T5
# (bus-result/bus-settled) and T6 (identity) stop needing them.
export def legacy-inbox-send [
    uid: string
    --run: string
    --payload: record
]: nothing -> record {
    # Validate before creating anything: a rejected message must leave no trace
    # in the runtime directory, not even an empty worker tree.
    validate-envelope (envelope-for $run $uid "inbox" $payload)
    ensure-worker-dirs $run $uid
    claim-slot (worker-dir $run $uid | path join "inbox") (envelope-for $run $uid "inbox" $payload)
}

# ------------------------------------------------------- peer-addressed send (sp029 T3)
#
# One bus, one queue per agent (## solution). A message is written once to
# `bus/messages/<msg-id>` and fanned out to `bus/queue/<uid>` for every
# recipient; nothing here is run-scoped or sequence-numbered, because nothing
# needs to be — a message id (`mint-msg-id`, sp029 T2) is unique without
# coordination, so concurrent senders never contend for anything.
#
# A queue row is exactly 32 bytes: the 26-character message id, a 5-byte
# suffix zone (5 spaces until read, `-read` once marked by T4's
# `queue-mark-read`), and a trailing newline. The width is load-bearing: T4
# marks a row read with a same-length write at its own offset while this
# code keeps appending to the end with `O_APPEND` — two operations that never
# have to look at, or lock against, each other.
export const QUEUE_SUFFIX_CHARS = 5
export const QUEUE_ROW_BYTES = $MSG_ID_CHARS + $QUEUE_SUFFIX_CHARS + 1

const QUEUE_UNREAD_SUFFIX = "     "

def queue-path [uid: string]: nothing -> string {
    project-dir | path join "queue" $uid
}

def queue-row [msg_id: string]: nothing -> string {
    $"($msg_id)($QUEUE_UNREAD_SUFFIX)\n"
}

# Append one unread row naming `msg_id` to `uid`'s queue.
#
# The bus is shared; a queue is not (## solution) — every sender appends to
# the SAME file many writers may be touching at once, so the append itself
# has to be safe with no lock. `O_APPEND` (`save --append`) already gives that
# for an EXISTING file. The one moment that is not automatically safe is the
# file's own creation: two first-time senders both finding no queue file and
# both trying to create it is exactly the race `ensure-dir` hit for
# directories, so it is handled the same way here — write the row to a
# private-mode scratch file first, then `ln` it into place. The winner's row
# is what the file starts with; the loser's `ln` fails because the target now
# exists, and it falls back to a plain append, landing its row right after
# the winner's.
export def queue-append [uid: string, msg_id: string]: nothing -> nothing {
    let path = (queue-path $uid)
    if (($path | path type) == "symlink") and not ($path | path exists) {
        error make {msg: $"refusing to append to the queue for ($uid): ($path) is a dangling symlink"}
    }

    let row = (queue-row $msg_id)
    if ($path | path exists) {
        $row | save --append --raw $path
        return
    }

    let scratch = ($path | path dirname | path join $".tmp.(random chars --length 10)")
    $row | save -f $scratch
    chmod 600 $scratch
    let linked = (do { ^ln $scratch $path } | complete)
    rm -f $scratch
    if $linked.exit_code != 0 {
        # Lost the create race: the file exists now (another sender made it,
        # or it always existed and the check above raced it) — append after
        # whatever is already there rather than losing this row.
        $row | save --append --raw $path
    }
}

def message-path [msg_id: string]: nothing -> string {
    project-dir | path join "messages" $msg_id
}

# Whether `uid`'s queue already holds the unread row `bus-stage-message` wrote
# for `msg_id`. A straight substring check on the row's own fixed 32-byte
# text: rows are append-only and never edited except in place by T4's
# `queue-mark-read` (a 5-byte suffix rewrite, so the id-plus-unread-suffix
# prefix this checks for is untouched by that), so if the exact bytes
# `queue-append` wrote are anywhere in the file, they are still there.
def queue-has-row [uid: string, msg_id: string]: nothing -> bool {
    let path = (queue-path $uid)
    if not ($path | path exists) { return false }
    (open --raw $path) | str contains (queue-row $msg_id)
}

# Every row in `uid`'s queue, in file order — the read side of the fixed-width
# format `queue-append` writes (sp029 T4).
#
# Newline-delimited, not fixed-byte-offset: splitting on the row's own `\n`
# re-syncs after a malformed row (one short of the full width — a disk-full
# mid-append, or hand-corrupted) instead of misreading every row after it at a
# shifted absolute offset. A row that is not exactly `MSG_ID_CHARS +
# QUEUE_SUFFIX_CHARS` characters between newlines is skipped, never
# misparsed: `## edge_cases` names a partially-written row explicitly, and
# silently swallowing it whole (rather than treating the survivable id+suffix
# text after it as its own row) is not an option either — a row is atomic or
# it does not count.
#
# Absent queue file is empty, not an error: a recipient nobody has sent to yet
# is not a fault.
export def queue-rows [uid: string]: nothing -> list<record> {
    let path = (queue-path $uid)
    if not ($path | path exists) { return [] }
    let raw = (open --raw $path)
    if ($raw | is-empty) { return [] }
    $raw
    | str trim --right --char "\n"
    | split row "\n"
    | where {|line| ($line | str length) == ($MSG_ID_CHARS + $QUEUE_SUFFIX_CHARS) }
    | each {|line| {
        id: ($line | str substring 0..<$MSG_ID_CHARS)
        read: (($line | str substring $MSG_ID_CHARS..) == "-read")
    }}
}

# Mark one row read, in place, at its own offset — the one deliberate
# exception to create-and-rename (`## plan` / `## conventions`): a whole-file
# rewrite would drop any row a concurrent sender appended between this
# function's read and its write, which is exactly the anti-pattern the fixed
# 5-byte suffix zone exists to make unnecessary.
#
# `str index-of` finds the row by its id (26 Crockford characters, ASCII, so
# character offset equals byte offset); the write itself is a single `dd`
# call with `oflag=seek_bytes` so the 5-byte suffix write is ONE `write(2)` at
# an absolute byte position — `conv=notrunc` so the file is never truncated
# or rewritten, `bs=5 count=1` (not `bs=1 count=5`) so it is one syscall, not
# five separate ones a concurrent read could catch mid-write. Overwriting
# `-read` with `-read` again is the same five bytes either way, so marking an
# already-marked row is naturally idempotent — two processes marking the same
# row race harmlessly.
export def queue-mark-read [uid: string, msg_id: string]: nothing -> nothing {
    let path = (queue-path $uid)
    if not ($path | path exists) {
        error make {msg: $"cannot mark ($msg_id) read: ($uid) has no queue file"}
    }
    let raw = (open --raw $path)
    let offset = ($raw | str index-of $msg_id)
    if $offset < 0 {
        error make {msg: $"cannot mark ($msg_id) read: no row in ($uid)'s queue names that id"}
    }
    let suffix_offset = $offset + $MSG_ID_CHARS
    "-read" | ^dd $"of=($path)" "bs=5" "count=1" $"seek=($suffix_offset)" "oflag=seek_bytes" "conv=notrunc" "status=none"
}

# Stage a message: mint its id, append every recipient's queue row, THEN write
# the envelope to a scratch name. The message is not yet visible to any reader
# — nothing in `bus/messages/` carries this id until `bus-publish-message`
# renames it into place. This split exists so a crash (or a test) can land
# between the two: every row already names the final id, and no message
# answers to it yet, which is exactly the state the fan-out anti-pattern in
# `## plan` warns against publishing INTO. Rows first, message last, keeps a
# reader that finds no message file reporting clean zero mail instead of
# erroring on a name nothing resolves.
#
# Rows are appended before the envelope is written (not after, as the prose
# in `## plan` lists them) so the message file's own mtime — set at its
# creation, not touched again by the rename — is provably later than every
# row it is behind. Which sub-step happens first between "write rows" and
# "write the not-yet-visible scratch envelope" carries no safety meaning on
# its own; only "rename last" does, and that still holds either way.
export def bus-stage-message [
    --to: list<string>
    --from: string
    --content: any
]: nothing -> record {
    # Validate before creating anything: a rejected message must leave no
    # trace in the runtime directory, not even an empty project tree —
    # `ensure-bus-dirs` runs only once the envelope is known-good.
    let recipients = ($to | default [] | uniq)
    let msg_id = (mint-msg-id)
    let envelope = {
        protocol: $PROTOCOL_VERSION
        kind: "inbox"
        id: $msg_id
        from: $from
        to: $recipients
        created: (now-stamp)
        content: $content
    }
    validate-envelope $envelope

    # sp029 dotfiles-6nvx.14: `validate-envelope` (and T2's `content-bytes`
    # check inside it) bounds CONTENT alone, deliberately — a 64 KiB content
    # field wrapped in the envelope's own JSON is already over 64 KiB total,
    # so that check has to ignore the wrapper to give an exact byte count for
    # content specifically. But nothing was then bounding the bytes actually
    # written to disk, and this is the first place anything is. So the 64 KiB
    # cap is enforced a second time here, on the real serialized size, which
    # is what `MAX_ENVELOPE_BYTES` and `envelope-bytes` were always for.
    let bytes = (envelope-bytes $envelope)
    if $bytes > $MAX_ENVELOPE_BYTES {
        error make {msg: $"envelope is ($bytes) bytes, over the 64 KiB cap: a bus message addresses work, it does not carry it"}
    }

    ensure-bus-dirs
    for uid in $recipients {
        queue-append $uid $msg_id
    }

    let scratch = (project-dir | path join "messages" $".tmp.($msg_id)")
    $envelope | to json | save -f $scratch
    chmod 600 $scratch

    {msg_id: $msg_id, scratch: $scratch, envelope: $envelope}
}

# Publish a staged message: the atomic step. `rename(2)` (`mv`, same
# filesystem) is what makes the message appear whole or not at all to a
# reader resolving a queue row's id against `bus/messages/`.
#
# Structural, not advisory: this refuses to publish unless every recipient in
# `staged.envelope.to` already has its row, so "publish a message before its
# fan-out completes" — the anti-pattern `## plan` names — cannot happen by
# calling these two functions in the wrong order or with a hand-built staged
# record. `bus-send` never hits this refusal, because `bus-stage-message`
# always finishes the fan-out first; it exists for a caller that reaches for
# `bus-publish-message` directly (T5's result-as-message move is the likely
# one) and gets the row count wrong.
export def bus-publish-message [staged: record]: nothing -> record {
    for uid in $staged.envelope.to {
        if not (queue-has-row $uid $staged.msg_id) {
            error make {msg: $"refusing to publish message ($staged.msg_id): no queue row for ($uid) — publishing before fan-out completes would address a message nobody is told about"}
        }
    }
    mv $staged.scratch (message-path $staged.msg_id)
    $staged.envelope
}

# Address a message to one or more agents' queues. `to` is deduplicated —
# addressing the same agent twice, including the sender addressing itself, is
# a sender mistake worth ignoring rather than a protocol violation
# (`validate-envelope`'s own comment on `to`). Sending never requires a
# recipient to exist: an address nobody has claimed yet is exactly as valid a
# `to` as one that is live, since the bus keeps no registry to check against.
export def bus-send [
    --to: list<string>
    --from: string
    --content: any
]: nothing -> record {
    bus-publish-message (bus-stage-message --to $to --from $from --content $content)
}

# Every unread row in `as`'s own queue, resolved against `bus/messages/` —
# sp029 T4's read side. No privileged reader (`## plan`'s named anti-pattern):
# every call is scoped by the caller's own address, reads no other agent's
# queue, and never lists `bus/messages/` itself — only specific ids a row
# already named are ever opened, so a message no queue points at is simply
# never looked at.
#
# A row naming an id that never resolves (T3's crash-before-publish ordering,
# or a pruned message) is silently absent from the result rather than an
# error: `## plan` calls this inert, and a reader treating it as inert is the
# whole reason the write side is allowed to crash between fan-out and
# publish at all.
#
# Non-destructive, at least once: this never marks anything itself.
# `queue-mark-read` is a separate, explicit call, so calling `wait` twice with
# nothing marked in between returns the same mail both times — there is no
# ack file to make that automatic, and there does not need to be one.

# Poll interval for a blocking wait. Short enough that a worker finishing
# feels immediate, long enough that a directory listing four times a second
# is not what the machine is doing with its life.
const WAIT_POLL = 250ms

export def bus-wait [
    --as: string
    --block
    --timeout: duration = 60sec
]: nothing -> any {
    if ($as | is-empty) {
        error make {msg: "wait needs --as: whose queue to read"}
    }
    let deadline = (date now) + $timeout
    loop {
        let unread = (queue-rows $as | where {|r| not $r.read })
        mut mail = []
        # `for`, not `each`: an `each` around a raised `error make` is silently
        # swallowed in this nushell (see read-box's own note on the same
        # shape), and a corrupt message file is exactly the case that must
        # fail loudly rather than vanish.
        for row in $unread {
            let path = (message-path $row.id)
            if ($path | path exists) {
                let raw = (open --raw $path)
                let parsed = (try { $raw | from json } catch {
                    error make {msg: $"unparseable message ($row.id) in ($as)'s queue: the bus fails closed rather than skipping a message"}
                })
                $mail = ($mail | append $parsed)
            }
            # else: inert row, see above — not an error, just no mail for it.
        }
        if ($mail | is-not-empty) { return ($mail | sort-by id) }
        if not $block { return [] }
        if (date now) >= $deadline { return [] }
        sleep $WAIT_POLL
    }
}

# Delete a message once no queue holds an unread row for it.
#
# A message is addressed to a fixed set of recipients at send time; it can be
# collected only once EVERY one of them has marked their own row read (or
# never will — the row exists nowhere any more, orphaned or never sent). This
# never inspects `to` on the envelope itself: the queues are the only
# authoritative record of who still has not read it, because that is the
# state a recipient actually changes.
#
# Rows naming a pruned message are left exactly as they are (`## plan` calls
# them inert): deleting the message never touches a queue, so a stale row
# some reader never got to keeps resolving to nothing, harmlessly, rather
# than being cleaned up here too — `queue-mark-read`/a future GC owns rows,
# `bus-prune` owns messages.
export def bus-prune []: nothing -> record {
    ensure-bus-dirs
    let dir = (project-dir)
    let queue_dir = ($dir | path join "queue")
    let messages_dir = ($dir | path join "messages")

    let queues = (if ($queue_dir | path exists) {
        ls $queue_dir | where type == file | get name | each {|p| $p | path basename }
    } else { [] })

    mut referenced = []
    for uid in $queues {
        let unread_ids = (queue-rows $uid | where {|r| not $r.read } | get id)
        $referenced = ($referenced | append $unread_ids)
    }
    let referenced = ($referenced | uniq)

    let messages = (if ($messages_dir | path exists) {
        ls $messages_dir
        | where type == file
        | get name
        | where {|n| not ($n | path basename | str starts-with ".tmp.") }
        | each {|n| $n | path basename }
    } else { [] })

    mut pruned = []
    for id in $messages {
        if $id not-in $referenced {
            rm -f (message-path $id)
            $pruned = ($pruned | append $id)
        }
    }
    {pruned: $pruned}
}

# Write a worker's outcome to its outbox.
export def bus-result [
    uid: string
    --run: string
    --result: record
]: nothing -> record {
    # The stage gate is applied here rather than at the caller, so a worker
    # cannot dodge it by taking a different code path. The stage comes from the
    # identity the orchestrator recorded at spawn; a worker with no identity
    # cannot say which stage it is, so its completion is refused outright
    # instead of being waved through ungated.
    let identity = (bus-identity-of $uid --run $run)
    if $identity == null {
        error make {msg: $"refusing a result from ($run)/($uid): no identity on the bus, so its stage gate cannot be applied"}
    }

    # A `complete` from an isolated worktree must be COMMITTED.
    #
    # Observed: a worker created its file, reported `complete`, and acceptance
    # then refused —
    #
    #     accept refused: refusing to clean up .../wk-timestamp-file.1: it
    #     holds uncommitted work, which acceptance does not license deleting
    #
    # — which is the right refusal at the wrong moment. By then the worker has
    # already declared success and gone quiet, so the operator is left holding
    # a finished worker that cannot be accepted and a worktree that cannot be
    # cleaned. Refusing at the REPORT puts the problem in front of the only
    # party that can fix it, while it is still working.
    #
    # This is the same failure work-do's Step 7 exists for: work-merge merges
    # the branch, not the worktree, so an uncommitted worktree is a branch with
    # zero commits and a merge that silently does nothing. The work survives
    # only because `git worktree remove` refuses to delete dirty state.
    #
    # Only `complete` is gated. `blocked`, `failed` and `waiting_human` are
    # exactly the statuses a worker should be able to report with a messy tree,
    # and refusing those would leave it no way to say so.
    #
    # A tree we cannot inspect is NOT refused: git missing, or a cwd that is not
    # a repository, is our failure to observe rather than the worker's failure
    # to commit, and accept's own guard still stands behind this. adr0017's
    # rule, applied to a gate rather than a verdict.
    # sp029 T8: isolation is now recorded directly on the identity at spawn
    # time, not looked up by skill name in a registry. Absent on an identity
    # from before this change (or one a fixture wrote directly), so the gate
    # simply does not apply to it — the runtime bus this identity lives in is
    # transient anyway.
    if (($result | get -o status) == "complete") and (($identity | get -o isolation | default "") == "worktree") {
        let dirty = (do { ^git -C $identity.cwd status --porcelain } | complete)
        if $dirty.exit_code == 0 and ($dirty.stdout | str trim | is-not-empty) {
            let files = ($dirty.stdout | lines | each {|l| $l | str trim } | first 5 | str join ", ")
            error make {msg: $"refusing `complete` from ($run)/($uid): ($identity.cwd) holds uncommitted work \(($files)). Commit it on ($identity.branch) first — acceptance deletes this worktree, and an uncommitted branch merges as a no-op, so reporting complete now loses the work"}
        }
    }

    validate-envelope (envelope-for $run $uid "result" $result)
    ensure-worker-dirs $run $uid
    let written = (claim-slot (worker-dir $run $uid | path join "outbox") (envelope-for $run $uid "result" $result))

    # sp029 T5: "a result is one message kind in the thread rather than the
    # bus's purpose" (## solution). When a commissioner is recorded, the
    # SAME content also travels as an ordinary peer message via T3's writer
    # and T4's reader, addressed to it — additive, not a replacement. The
    # legacy outbox write above is unchanged on purpose: bus-status,
    # derive-state and worker-accept read ONLY that, and migrating them off
    # it is not this task's job (dotfiles-v1zt's bus-result call site is
    # therefore still here, not cleared).
    let commissioner = ($identity | get -o commissioner)
    if ($commissioner | is-not-empty) {
        bus-send --to [$commissioner] --from $uid --content $result
    }

    $written
}

# Report that a worker's agent settled without reporting anything.
#
# dotfiles-87bt: this writer was missing, so `settled-without-result` above
# built an envelope nothing ever persisted. A worker that finished its turn
# without calling the result tool therefore produced SILENCE — state stayed
# `running`, `wait` returned nothing, and an initiator could not distinguish
# "still working" from "gave up and went quiet". The absence of a result is
# itself the report, which is the whole point of SETTLED_WITHOUT_RESULT.
#
# Reported at most once per worker, and never when a real result already
# exists: `agent_settled` fires again on every subsequent turn, and the normal
# successful path is "worker called the tool, THEN its turn settled". Emitting
# an error there would turn every healthy worker into a failed one, and
# stacking one error per settle would bury the first real outcome.
export def bus-settled [uid: string, --run: string]: nothing -> record {
    # sp029 T5: only a COMMISSIONED agent owes anyone a report — "an
    # uncommissioned peer that finishes a turn is simply done talking"
    # (## solution). `worker-spawn` now records `commissioner` on every
    # identity it creates, so ABSENCE of the field is the honest signal that
    # nothing commissioned this agent (a future T7 self-registering agent
    # never goes through worker-spawn, so it never gets one) — not a
    # backward-compatibility shim. A present-but-empty value is refused the
    # same way: recorded-and-blank is not a real address either.
    let identity = (bus-identity-of $uid --run $run)
    let uncommissioned = (
        $identity != null
        and (($identity | get -o commissioner) | is-empty)
    )
    if $uncommissioned {
        return {reported: false, reason: "no commissioner recorded; an uncommissioned agent settling has nothing to report", run: $run, uid: $uid}
    }

    ensure-worker-dirs $run $uid
    let existing = (read-box (worker-dir $run $uid | path join "outbox"))
    if ($existing | is-not-empty) {
        return {reported: false, reason: "an outcome was already reported", run: $run, uid: $uid}
    }

    let envelope = (envelope-for $run $uid "error" {
        code: "protocol_error"
        detail: "agent settled without calling the typed result tool; completion is never inferred from an idle prompt, an exited pane, or assistant prose"
    })
    validate-envelope $envelope
    let written = (claim-slot (worker-dir $run $uid | path join "outbox") $envelope)
    {reported: true, run: $run, uid: $uid, sequence: $written.sequence}
}

# Everything addressed to one worker.
export def bus-inbox [uid: string, --run: string]: nothing -> list<record> {
    read-box (worker-dir $run $uid | path join "inbox")
}

# sp029 T4: this whole run/uid, ack-file-addressed result path is LEGACY.
# T9 moved `main wait`/`main result`/`main settled` onto the project-addressed
# bus (`bus-wait`, `bus-result`'s forwarding), and `ack` is gone from the CLI
# entirely, so `legacy-bus-wait` and `legacy-bus-ack` below have NO production
# caller left in this module. They are kept, deliberately, for two reasons: (1)
# `bus-result` still ALSO writes to this legacy, sequence-numbered outbox
# (dotfiles-v1zt: additive, not migrated), and a clutch of regression tests —
# dotfiles-nig0/ycvl/pwxf, the `reopened`-marker guards on `worker-resume` —
# read it back through exactly these functions to prove that legacy write path
# still behaves; (2) `bus-status`'s `unacked` count still depends on
# `legacy-ack-path` (kept, still called, NOT dead) for the same reason: T5
# additively forwards a commissioned result to the new bus, it does not tell
# `bus-status` how to count "unacked" against a queue instead of an ack file,
# and that correlation (which queued message id corresponds to which legacy
# outbox sequence) has no clean answer without a design of its own. Judged for
# dotfiles-hp6v: NOT closed. `legacy-bus-wait`/`legacy-bus-pending`/
# `legacy-bus-ack` are unreachable from any CLI verb now, but retiring them
# means either accepting the regression tests above lose their probe or
# rewriting each to read the legacy outbox some other way, AND still leaves
# `legacy-ack-path` standing for `bus-status`. Follow-up needed: design what
# `bus-status.unacked` means once a result is a queued message, migrate the
# regression tests off `legacy-bus-wait`/`legacy-bus-ack` accordingly, and only
# then drop all four together.
def legacy-ack-path [run: string, uid: string, sequence: int]: nothing -> string {
    worker-dir $run $uid | path join "outbox" $"($sequence).ack"
}

# Every unacknowledged result in a run, oldest first, across all its workers.
#
# Superseded envelopes are not pending (dotfiles-nig0). `resume` writes a
# `reopened` marker holding the sequence it sent back, and `derive-state`
# already reads it: while the marker covers a result, that result has been
# answered and the worker is running again. Delivery has to agree, or `wait`
# hands an orchestrator a `complete` envelope for work it rejected seconds ago
# and there is no way to tell it from a fresh report.
#
# An ack cannot substitute for this. Acking is what stops redelivery, and
# `legacy-bus-ack` releases the worker's window — the window `resume` requires alive —
# so "ack it, then send it back" is not an available ordering.
export def legacy-bus-pending [run: string]: nothing -> list<record> {
    let dir = (run-dir $run)
    if not ($dir | path exists) { return [] }
    let workers = (ls $dir | where type == dir | get name | sort)

    # `for`, not `each`, for the same reason as read-box: an `each` here would
    # swallow the read-box rejection it is supposed to surface.
    mut pending = []
    for w in $workers {
        let uid = ($w | path basename)
        let reopened = (marker-value $run $uid "reopened")
        # 0 covers nothing: sequences start at 1.
        let answered = (if ($reopened | is-empty) { 0 } else { $reopened | into int })
        let unacked = (
            read-box ($w | path join "outbox")
            | where {|e| $e.sequence > $answered }
            | where {|e| not (legacy-ack-path $run $uid $e.sequence | path exists) }
        )
        $pending = ($pending | append $unacked)
    }
    $pending | sort-by created
}

# The oldest unacknowledged result in a run, or nothing.
#
# Non-destructive by design: an initiator that dies between reading this and
# acknowledging it must see the same envelope on restart. Delivery state is the
# `.ack` file on disk, never anything held in the reader.
# ------------------------------------------------------------- minting
#
# An agent that must supply an address and has no way to produce one shells out
# for it — observed live as a bare `uuidgen` line in the operator's transcript,
# which is 36 characters of noise that buys nothing to look at. The tool mints
# the address instead.
#
# `<role>-<n>` rather than a uuid because this name is worn in public: it is
# the tmux window, the frame's row, and the thing an operator says out loud.
# `impl-2` survives all three; `0a77b1d8-3eed-4ff0-8bda-78159973b144` does not.

# The lowest free `<role>-<n>` in a PROJECT (dotfiles-bg65).
#
# `repo` is any path inside the project — the repo, or a worker's own `wk-*`
# worktree, which `resolve-project-slug` walks back to the same main worktree
# — and defaults to the caller's own repository, exactly like `resolve-run`.
# It took a `run` before, and the run is gone rather than ignored: a per-run
# search stopped being a namespace the moment sp029 T9 gave every spawn its
# own run (see `project-uids` for the whole failure).
export def mint-uid [role: string, repo: string = ""]: nothing -> string {
    let prefix = (if ($role | is-empty) { "w" } else { $role })
    let taken = (project-uids $repo)
    mut n = 1
    while $"($prefix)-($n)" in $taken { $n = $n + 1 }
    $"($prefix)-($n)"
}

# The tmux session group to host a worker's window.
#
# Derived rather than demanded. The orchestrator is itself running in a tmux
# session, and that session's group is where the operator is already looking —
# which is the only sensible place to put a window they are meant to see. It
# was a required argument, and the refusal for omitting it was the last piece
# of ceremony left in a spawn call:
#
#     spawn refused: spawn needs --project: the tmux session group to host the
#     window, e.g. dotfiles
#
# Nothing about that is a decision the caller was making.
#
# Found from $TMUX_PANE via `list-panes`, deliberately NOT via
# `display-message`. That verb is on the forbidden list because `-p` makes it a
# read channel that could carry state, and the static guard enforces it — the
# right answer is not to argue for an exception but to use the probe that is
# already allowed and already used by worker-liveness.
#
# Keyed on the pane rather than on "the current session", because tmux ANSWERS
# either way: asked from outside, it reports whichever session was most
# recently active, which is a guess. A worker window placed in a guessed group
# is one the operator will not find. No $TMUX_PANE means no derivation, and the
# caller is told which flag to pass.
#
# A grouped session lists its pane once per member, all with the same group, so
# the first row is as good as any. An ungrouped session reports an empty group
# and its own name is the host.
export def current-session-group []: nothing -> string {
    let pane = ($env | get -o TMUX_PANE | default "")
    if ($pane | is-empty) { return "" }
    let listed = (do { ^tmux list-panes -a -F "#{pane_id}\t#{session_group}\t#{session_name}" } | complete)
    if $listed.exit_code != 0 { return "" }
    let mine = (
        $listed.stdout
        | lines
        | each {|l| $l | split row "\t" }
        | where {|r| ($r | length) >= 3 and ($r | first | str trim) == $pane }
    )
    if ($mine | is-empty) { return "" }
    let row = ($mine | first)
    let group = ($row | get 1 | str trim)
    if ($group | is-not-empty) { $group } else { $row | get 2 | str trim }
}

# The git repository enclosing the current directory.
#
# Same reasoning as the session group: the orchestrator is standing in a
# repository, and that is the one it means. Empty when it is not, so the caller
# gets a named refusal rather than a worker pointed somewhere arbitrary.
export def current-repo []: nothing -> string {
    let top = (do { ^git rev-parse --show-toplevel } | complete)
    if $top.exit_code != 0 { return "" }
    $top.stdout | str trim
}

# A fresh id for the worker's Pi session.
#
# Passed to `pi --session-id` to CREATE a session, so it only has to be unique
# — there is nothing to look up and nothing for a caller to know. The tool
# parameter used to be documented as "a fresh uuid for the worker's Pi
# session", which is an instruction to go and find one: the agent shelled out
# to `uuidgen` and the operator got a bare 36-character line for their trouble.
export def mint-session []: nothing -> string {
    random uuid
}

# The lowest free `r<n>` at the legacy bus root.
#
# sp029 retires the run concept in favor of project scoping (`project-dir`),
# so this is a placeholder, not a design: `spawn` still threads a `run`
# string down to `worker-dir` until T9 redesigns the CLI to address by
# `--to` instead. Deliberately renamed off the old allocator's name — sp029
# T1 retires that name from the module's exported surface — but still
# exported: this is live production logic reached from `main spawn` with no
# `--run` given, not dead code, so it stays directly testable rather than
# only reachable through a CLI round trip.
#
# Directories that are not shaped `r<n>` are ignored rather than parsed: a run
# an operator named `x4` says nothing about which `r<n>` is free, and reading a
# number out of it would hand back an address already in use.
export def next-run-id []: nothing -> string {
    let root = (bus-root)
    let taken = (if ($root | path exists) {
        ls $root | where type == dir | get name | each {|d| $d | path basename }
    } else { [] })
    mut n = 1
    while $"r($n)" in $taken { $n = $n + 1 }
    $"r($n)"
}

# sp029 T4: LEGACY — run/uid-addressed, reads the outbox via legacy-bus-
# pending. `main wait` moved onto the project/queue-addressed `bus-wait`
# further down (T9); this has no CLI caller left, kept only for the
# regression tests reading the legacy outbox directly — see the comment
# above `legacy-ack-path` for the full dotfiles-hp6v judgment (not closed).
export def legacy-bus-wait [
    --run: string
    --uid: string = ""
    --json
    # Without --block this peeks and answers at once, which is what a script
    # doing its own loop needs. WITH it, the verb does what its name says.
    #
    # It did not, and that had a cost: an agent told to "`wait` for its typed
    # result" called it, got nothing, decided out loud that it needed a polling
    # mechanism, and polled the worker's tmux pane — the one thing the
    # transport boundary forbids as a completion signal. A verb named `wait`
    # that does not wait sends the caller looking for a channel that is not the
    # bus.
    --block
    # Bounded, and bounded low: this runs inside a host tool call, and a wait
    # that outlives the host's own timeout is indistinguishable from a hang.
    --timeout: duration = 60sec
    # Skip results the caller has already read (dotfiles-i0hz).
    #
    # An initiator that hands a reported-but-unacked worker more work could not
    # learn when the NEW work was done. `wait` keeps handing over the earlier
    # envelope — rightly, because unacknowledged IS pending — and `ack`, the
    # only thing that clears it, releases the worker that was supposed to do
    # the follow-up. Neither order works, so the caller says what it has seen.
    #
    # Deliberately NOT an implicit ack. The earlier result is still owed one:
    # this says "not the answer I am waiting for", not "I am done with it".
    # `--after 0`, the default, is the flag's absence.
    --after: int = 0
]: nothing -> any {
    if $after < 0 {
        error make {msg: $"wait --after ($after) is not a sequence: sequences start at 1, and 0 means everything"}
    }
    # Sequences are numbered PER WORKER, so `--after 2` across a run would name
    # a different envelope for each of them — and skipping another worker's
    # sequence 1 because this one is on 2 is exactly the stale-mail confusion
    # the flag exists to prevent. Refused rather than interpreted.
    if $after > 0 and ($uid | is-empty) {
        error make {msg: $"wait --after needs --uid: sequences are numbered per worker, so an unscoped --after would mean a different envelope for each of them and could skip mail this caller has never seen"}
    }
    let deadline = (date now) + $timeout
    loop {
        # Unscoped, this is the oldest unacknowledged result ACROSS the run,
        # which is what an orchestrator draining many workers wants. `--uid`
        # narrows it to one, which is what anyone waiting on a PARTICULAR
        # worker wants: a run that still holds a finished worker with an unacked
        # envelope would otherwise hand its answer to whoever asked next
        # (dotfiles-idzp's stale-state shape, in the mailbox rather than the
        # window list).
        let all = (legacy-bus-pending $run)
        let scoped = (if ($uid | is-empty) { $all } else { $all | where uid == $uid })
        let pending = (if $after > 0 { $scoped | where sequence > $after } else { $scoped })
        if ($pending | is-not-empty) {
            let next = ($pending | first)
            return (if $json { $next | to json } else { $next })
        }
        if not $block { return null }
        # Checked before sleeping, so a timeout of zero returns at once rather
        # than costing one interval.
        if (date now) >= $deadline { return null }
        sleep $WAIT_POLL
    }
}

# Record delivery of one result. This is a receipt, NOT acceptance: the work
# still needs review, and the worker stays visible until it is explicitly
# accepted.
# Acknowledge a result AND release the worker that reported it.
#
# A worker that has reported is done working, and it used to go on holding a pi
# process and a tmux window until something accepted it. Twenty-nine workers
# were doing exactly that on this box, one per smoke run — the expensive
# leftover, next to which the directories were nothing.
#
# The ack is the right moment because it is the initiator saying it HAS the
# result: before that the envelope is still being redelivered and a live worker
# is still the thing being talked about. What is released is the DISPLAY half —
# the window, and the process inside it. The worktree and the branch hold the
# work and stay until `accept` or a sweep; the identity envelope holds the
# session id and stays for good, which is what makes the worker respawnable
# with no window, no process and no directory of its own.
#
# The receipt is written FIRST and the release is best effort. An unreachable
# tmux must not cost the initiator its ack, or `wait` hands it the same
# envelope forever — so the outcome is reported rather than thrown.
#
# sp029 T4: LEGACY, same reason as `legacy-bus-wait` above — `main ack` still
# calls this. The new model has no ack file at all: a row is marked read in
# place by `queue-mark-read`. Tracked for removal as dotfiles-hp6v.
export def legacy-bus-ack [
    --run: string
    --uid: string
    --sequence: int
    --socket: string = ""
]: nothing -> record {
    let envelope = (worker-dir $run $uid | path join "outbox" $"($sequence).json")
    if not ($envelope | path exists) {
        error make {msg: $"cannot acknowledge ($run)/($uid) sequence ($sequence): no such result envelope"}
    }
    let marker = (legacy-ack-path $run $uid $sequence)
    let scratch = ($marker + $".tmp.(random chars --length 10)")
    (now-stamp) | save -f $scratch
    chmod 600 $scratch
    mv -f $scratch $marker

    let identity = (bus-identity-of $uid --run $run)
    if $identity == null {
        return {run: $run, uid: $uid, sequence: $sequence, released: false, reason: "no identity on the bus, so there is nothing to release"}
    }
    let target = (window-target $identity)
    let seen = (worker-liveness $target --socket $socket)
    if $seen.verdict == "gone" {
        return {run: $run, uid: $uid, sequence: $sequence, released: false, reason: $"window ($identity.window) is already gone"}
    }
    if $seen.verdict == "unknown" {
        return {run: $run, uid: $uid, sequence: $sequence, released: false, reason: $"could not reach the display host to release ($identity.window): ($seen.reason? | default "tmux did not answer")"}
    }
    let killed = (do { ^tmux ...(tmux-args $socket) kill-window -t $target } | complete)
    if $killed.exit_code != 0 {
        return {run: $run, uid: $uid, sequence: $sequence, released: false, reason: $"could not release ($identity.window): ($killed.stderr | str trim)"}
    }
    {run: $run, uid: $uid, sequence: $sequence, released: true, window: $identity.window}
}

# What is known about one worker.
#
# `state` is the status of its latest result. A worker with no evidence at all
# reports `unknown` — an observation, not a persisted state, and per adr0017
# never a licence to stop, accept, or delete anything.
# The one place a worker's state is decided.
#
# Extracted from bus-status so the timeline can say what the state was after
# each event without a second implementation of these rules. Two copies of a
# precedence table is two answers to "what is this worker" the first time
# someone edits one — and the whole reason the timeline is worth having is
# that it agrees with the frame.
#
# Pure: takes the evidence, returns the verdict, touches no disk.
#
# `markers` is {accepted?: bool, stopped?: bool, waiting_human?: bool,
# reopened?: string}; `results` is the outbox, oldest first.
#
# `accepted`/`stopped` are read off the durable placement record (sp029 T6),
# so this precedence holds even when `results` is empty because the runtime
# bus tree was wiped out from under a worker that was already decided — which
# is the property the wipe-survival case in `worktree-cases.nu` exists to
# prove. `waiting_human`/`reopened` still come off the legacy runtime tree
# (see the comment on `marker-path`); they read as absent post-wipe, which
# only ever demotes a worker toward `created`, never toward a false verdict.
export def derive-state [results: list<record>, markers: record]: nothing -> string {
    # Externally granted states win over anything the worker reported: a
    # reviewer's acceptance or an operator's teardown is later, and more
    # authoritative, than the worker's own last word about itself.
    if ($markers | get -o accepted | default false) { return "accepted" }
    if ($markers | get -o stopped | default false) { return "stopped" }
    if ($markers | get -o waiting_human | default false) { return "waiting_human" }

    let newest = (if ($results | is-empty) { 0 } else { $results | last | get sequence })
    # `reopened` is the subtle one. A rejected worker's last envelope still
    # says `complete` — that report was true when it was written — so the
    # marker records WHICH result was sent back. While it covers the newest
    # result, the worker is running again; once the worker reports afresh, the
    # newer sequence outranks the marker and its real outcome shows through.
    let reopened = ($markers | get -o reopened | default "")
    if ($reopened | is-not-empty) and (($reopened | into int) >= $newest) { return "running" }

    # Spawned and has never reported. `created` is the declared WORKER_STATE
    # for exactly this: alive and has not said anything yet, which needs a
    # different response from "reported once and was sent back to work".
    if ($results | is-empty) { return "created" }

    # Dispatch on KIND, not on a field. An outbox holds `result` envelopes
    # (payload.status) and `error` envelopes (payload.code) — different shapes
    # — so reading `payload.status` off whatever came last crashed with
    # "column 'status' is missing" the first time a worker settled without
    # reporting.
    let latest = ($results | last)
    if $latest.kind == "error" { $latest.payload.code } else { $latest.payload.status }
}

# The markers that bear on a worker's state, as derive-state wants them.
def state-markers [run: string, uid: string]: nothing -> record {
    {
        accepted: (marker-path $run $uid "accepted" | path exists)
        stopped: (marker-path $run $uid "stopped" | path exists)
        waiting_human: (marker-path $run $uid "waiting_human" | path exists)
        reopened: (marker-value $run $uid "reopened")
    }
}

export def bus-status [uid: string, --run: string]: nothing -> record {
    # Resolved unconditionally, and BEFORE the identity check: `worker-dir`
    # is what raises the actionable "XDG_RUNTIME_DIR is unset" error, and
    # every caller of this verb must still see that failure rather than a
    # silently successful "unknown" answered from durable state alone.
    let dir = (worker-dir $run $uid)
    # Identity, not the runtime directory, is the EXISTENCE check now (sp029
    # T6): identity is durable, so "unknown" means no identity was ever
    # recorded — never "the runtime bus tree happens to be gone right now",
    # which would misreport a wiped-but-real worker as if it never existed.
    let identity = (bus-identity-of $uid --run $run)
    if $identity == null {
        return {run: $run, uid: $uid, state: "unknown", unacked: 0, results: 0, inbox: 0}
    }
    let results = (if ($dir | path exists) { read-box ($dir | path join "outbox") } else { [] })
    # The precedence rules, and the reasoning for them, live with derive-state.
    let markers = (state-markers $run $uid)
    let state = (derive-state $results $markers)
    # `unacked` counts what DELIVERY would hand over, which is why it reads the
    # `reopened` marker the way legacy-bus-pending does (dotfiles-ycvl). It is the
    # field an orchestrator skims to decide whether to call `wait` at all, so
    # counting a result that was already sent back sends it looking for mail
    # that is not there. `results` stays the raw count: that one is history.
    let answered = (if ($markers.reopened | is-empty) { 0 } else { $markers.reopened | into int })
    let unacked = (
        $results
        | where {|e| $e.sequence > $answered }
        | where {|e| not (legacy-ack-path $run $uid $e.sequence | path exists) }
    )
    {
        run: $run
        uid: $uid
        state: $state
        unacked: ($unacked | length)
        results: ($results | length)
        inbox: (if ($dir | path exists) { read-box ($dir | path join "inbox") | length } else { 0 })
    }
}

# ========================================================= worker worktrees
#
# Each worker gets its own git worktree at `<repo>/.worktrees/wk-<task>.<N>`
# on a branch of the same name. Directory and branch share a name so
# `git worktree list` is self-documenting and a later sweep can map a directory
# back to its task mechanically.
#
# The whole layer is biased toward refusing. Allocation must never hand back a
# worktree that already holds someone's work, and cleanup must never delete
# work that was not both committed and accepted. A false refusal costs a retry;
# a false deletion costs the work, and `git worktree remove` is the last thing
# standing between an uncommitted change and oblivion.

const WORKTREE_SUBDIR = ".worktrees"
const MAX_ITERATION_ATTEMPTS = 64

def worktrees-dir [repo: string]: nothing -> string { $repo | path join $WORKTREE_SUBDIR }

# Every branch git knows about, whether or not it has a directory.
#
# Checking directories on disk is not enough: a swept iteration leaves its
# branch behind, and handing that branch to a new worker would stack two
# attempts' history on one ref.
def known-branches [repo: string]: nothing -> list<string> {
    ^git -C $repo branch --list --format "%(refname:short)"
    | lines
    | each {|b| $b | str trim }
    | where {|b| ($b | str length) > 0 }
}

# `git worktree list --porcelain` as records of {path, branch, locked}.
def registered-worktrees [repo: string]: nothing -> list<record> {
    let out = (^git -C $repo worktree list --porcelain | lines)
    mut entries = []
    mut current = {path: "", branch: "", locked: false}
    for line in $out {
        if ($line | str starts-with "worktree ") {
            if ($current.path | is-not-empty) { $entries = ($entries | append $current) }
            $current = {path: ($line | str substring 9..), branch: "", locked: false}
        } else if ($line | str starts-with "branch ") {
            $current = ($current | update branch ($line | str substring 7.. | str replace "refs/heads/" ""))
        } else if ($line | str starts-with "locked") {
            $current = ($current | update locked true)
        }
    }
    if ($current.path | is-not-empty) { $entries = ($entries | append $current) }
    $entries
}

# True when the worktree at `path` has any change git would lose.
#
# `--porcelain` with untracked files included: an untracked scratch file is
# exactly as unrecoverable as an unstaged edit, and is the likelier of the two
# to be someone's notes.
def worktree-dirty? [path: string]: nothing -> bool {
    (^git -C $path status --porcelain --untracked-files=all | str trim | is-not-empty)
}

# Allocate the next free `wk-<task>.<N>` worktree.
#
# Serialisation reuses the bus's link(2) idiom rather than a lock file with a
# timeout: creating the branch is itself the claim. `git branch` fails if the
# ref already exists, so two racing allocators cannot both take an iteration —
# the loser sees the failure and moves to the next number. There is no window
# in which both believe they own it, and no lock to leak if a process dies.
export def worktree-allocate [--repo: string, --task: string] {
    let repo = (expand-path $repo)
    let base = (worktrees-dir $repo)
    if not ($base | path exists) { mkdir $base }

    # First of two independent guards against reusing an occupied ref. This
    # scan skips past iterations that already exist; `git worktree add -b`
    # below refuses an existing branch outright. Either alone is sufficient,
    # and they fail differently — the scan cannot see a ref created a
    # microsecond later, and the atomic create cannot tell a lost race from a
    # real error without retrying. Keeping both is deliberate, not redundant.
    # Mutating either one on its own leaves the suite green; the invariant they
    # jointly protect (an existing branch is never moved or reset) is asserted
    # directly instead.
    let taken = (known-branches $repo)
    mut n = (
        $taken
        | where {|b| $b | str starts-with $"($BRANCH_PREFIX)($task)." }
        | each {|b| try { $b | split row "." | last | into int } catch { -1 } }
        | append (-1)
        | math max
    )

    mut attempts = 0
    loop {
        $n = $n + 1
        $attempts = $attempts + 1
        if $attempts > $MAX_ITERATION_ATTEMPTS {
            error make {msg: $"could not allocate a worktree for ($task) after ($MAX_ITERATION_ATTEMPTS) attempts"}
        }

        let branch = $"($BRANCH_PREFIX)($task).($n)"
        let path = ($base | path join $branch)
        if ($path | path exists) { continue }

        # `git worktree add -b` creates the branch and the directory in one
        # step and fails if the branch already exists — that failure IS the
        # lost race, so it is a retry rather than an error.
        let added = (do { ^git -C $repo worktree add --quiet -b $branch $path } | complete)
        if $added.exit_code == 0 {
            return {branch: $branch, path: $path, iteration: $n, repo: $repo}
        }
    }
}

# Confirm a worktree is this worker's and is safe to use.
#
# Four separate refusals, because they mean different things to whoever reads
# the error: not registered (git does not know it), wrong branch (someone
# else's), locked (deliberately held), dirty (holds work).
export def worktree-validate [--repo: string, --path: string, --branch: string] {
    if not ($path | path exists) {
        error make {msg: $"worktree path does not exist: ($path)"}
    }
    let entry = (registered-worktrees $repo | where path == $path)
    if ($entry | is-empty) {
        error make {msg: $"($path) is not registered as a worktree of ($repo): git does not know about it"}
    }
    let found = ($entry | first)
    if $found.branch != $branch {
        error make {msg: $"worktree ($path) is on branch ($found.branch), not ($branch): it belongs to another worker"}
    }
    if $found.locked {
        error make {msg: $"worktree ($path) is locked: someone is deliberately holding it"}
    }
    if (worktree-dirty? $path) {
        error make {msg: $"worktree ($path) holds uncommitted work"}
    }
}

# Refs OTHER than this branch that already contain its tip.
#
# This is the question `git branch -d` is really asking, asked properly. `-d`
# compares the branch against HEAD and its upstream and nothing else, so it
# declines a branch whose commits are perfectly safe on a third ref — and,
# worse for a bus that deletes things, it answers "not merged" for the one case
# where deleting really would end the only copy AND for several where it would
# not. `--contains` separates them: a non-empty answer names somewhere else the
# work survives.
#
# refs/heads and refs/remotes only. A tag is not a place work continues to be
# reachable from a branch's point of view, and refs/dolt (this repo's issue
# database) is nobody's evidence about source history.
def refs-containing [repo: string, branch: string]: nothing -> list<string> {
    let out = (do {
        ^git -C $repo for-each-ref --contains $branch --format "%(refname)" refs/heads refs/remotes
    } | complete)
    if $out.exit_code != 0 { return [] }
    $out.stdout
    | lines
    | each {|l| $l | str trim }
    | where {|r| ($r | is-not-empty) and $r != $"refs/heads/($branch)" }
}

def branch-exists? [repo: string, branch: string]: nothing -> bool {
    (do { ^git -C $repo rev-parse --verify --quiet $"refs/heads/($branch)" } | complete).exit_code == 0
}

# Everything that would stop a cleanup, asked BEFORE anything is touched.
#
# Separated from the destructive half because the order used to be fatal
# (dotfiles-pwxf): `git worktree remove` ran, `git branch -d` then declined,
# and the caller was left with the irreversible half done, no acceptance
# marker, and a retry that could only re-run the same refusal. A refusal has to
# cost nothing, which means every question is asked while everything still
# stands.
#
# `worker-accept` calls this before it kills the window, for the same reason.
export def worktree-cleanup-guard [
    --repo: string
    --path: string
    --branch: string
    --accepted
    --merged-into: string = ""
] {
    let repo = (expand-path $repo)
    let path = (expand-path $path)
    if not $accepted and ($merged_into | is-empty) {
        error make {msg: $"refusing to clean up ($path): no acceptance or merge evidence. A completed worker stays visible until something explicitly says the work is done with"}
    }

    if ($merged_into | is-not-empty) {
        let merged = (do { ^git -C $repo merge-base --is-ancestor $branch $merged_into } | complete)
        if $merged.exit_code != 0 {
            error make {msg: $"refusing to clean up ($branch): it is not merged into ($merged_into). The merge claim is verified against git, not taken on the caller's word"}
        }
    }

    # The main worktree is never a worker's to delete. A stage declared
    # (dotfiles-ptba), so `worker-accept` reaches here with identity.cwd set to
    # it. git refuses on its own — but only after the accept sequence has
    # already killed the window, and with a message about working trees rather
    # than about what the caller did wrong.
    if $path == (main-worktree $repo) {
        error make {msg: $"refusing to clean up ($path): that is the main worktree, not a worker's. A stage declared isolation=main runs there and shares it with the operator; only its own isolated worktree is a worker's to remove"}
    }

    if ($path | path exists) and (worktree-dirty? $path) {
        error make {msg: $"refusing to clean up ($path): it holds uncommitted work, which acceptance does not license deleting"}
    }

    # Acceptance says the RESULT was taken. It does not say the commits went
    # anywhere, and on this bus they usually have not: a worker commits to its
    # own branch and something else lands it later. So the branch is only
    # deletable once its tip is reachable from another ref, and the refusal
    # names the ways out rather than leaving the operator to invent one.
    if (branch-exists? $repo $branch) and ((refs-containing $repo $branch) | is-empty) {
        error make {msg: $"refusing to clean up ($branch): its commits are on no other ref, so deleting it would end the only copy. Nothing has been touched. Land it first \(merge, cherry-pick or push it\) and clean up again, or `stop` the worker to keep both the tree and the branch"}
    }
}

# Remove a worker's worktree and branch — only with evidence that the work is
# finished with.
#
# Three independent gates, all of them in `worktree-cleanup-guard` above and
# all asked before the first destructive call: evidence (`--accepted`, or a
# `--merged-into` claim verified against git), cleanliness (uncommitted or
# untracked files block removal regardless of evidence), and preservation (the
# branch's commits must be reachable from some other ref).
#
# `git worktree remove` keeps its safety flags off: it is the last net under
# the dirty check. The branch delete is `-D` BECAUSE the guard has already
# proven what `-d` only approximates — that another ref contains this tip. `-d`
# here would re-ask a weaker version of the same question and decline work that
# is demonstrably safe on a third ref.
#
# Idempotent by design: a tree already gone and a branch already deleted are
# the finished state, not an error. The old code raised on a missing branch,
# which meant a cleanup that had partly happened — by hand, or by a previous
# attempt — could never be completed, and the worker could never reach
# `accepted`.
export def worktree-cleanup [
    --repo: string
    --path: string
    --branch: string
    --accepted
    --merged-into: string = ""
] {
    let repo = (expand-path $repo)
    let path = (expand-path $path)
    (worktree-cleanup-guard --repo $repo --path $path --branch $branch
        --accepted=$accepted --merged-into $merged_into)

    if ($path | path exists) {
        let removed = (do { ^git -C $repo worktree remove $path } | complete)
        if $removed.exit_code != 0 {
            error make {msg: $"could not remove worktree ($path): ($removed.stderr | str trim)"}
        }
    }

    if (branch-exists? $repo $branch) {
        let deleted = (do { ^git -C $repo branch -D $branch } | complete)
        if $deleted.exit_code != 0 {
            error make {msg: $"worktree ($path) removed, but branch ($branch) was not deleted: ($deleted.stderr | str trim). Bus metadata is intact; finish by hand"}
        }
    }
}

# Every worker the bus knows, with the tree and branch it claimed.
#
# Cheaper than `worker-roster` on purpose: no tmux probe. A sweep asks "does
# anyone still own this directory", and tmux cannot answer that — a worker
# whose window was killed still owns its tree until its state says otherwise.
#
# Enumerated from the DURABLE placement record (sp029 T6), keyed by `repo`
# directly, never from the runtime bus tree: that tree is exactly what may be
# gone by the time a sweep runs (a wiped login session, or one that never
# happened on this machine at all), and a sweep that could only see live
# claims when the runtime tree happens to still exist would treat every
# worker as unclaimed the moment it does not — which is precisely the
# scenario `accept`/`reclaim` must not get wrong, since both delete trees on
# this evidence.
def bus-claims [repo: string]: nothing -> list<record> {
    let slug = (project-slug (main-worktree $repo))
    let dir = (state-root | path join $slug "agents")
    if not ($dir | path exists) { return [] }
    # `agents/<run>/<uid>/` — see the comment on `agent-state-dir` for why the
    # `run` level is still there. A uid appears under exactly one of them now
    # that uniqueness is project-wide (dotfiles-bg65), so this walks the level
    # rather than meaning anything by it.
    ls $dir | where type == dir | get name | each {|run_dir|
        let run = ($run_dir | path basename)
        ls $run_dir | where type == dir | get name | each {|uid_dir|
            let uid = ($uid_dir | path basename)
            let records = (read-box ($uid_dir | path join "identity"))
            if ($records | is-empty) { [] } else {
                let envelope = ($records | last)
                let identity = $envelope.payload
                [{
                    run: $run
                    uid: $uid
                    state: (bus-status $uid --run $run | get state)
                    cwd: (expand-path $identity.cwd)
                    branch: $identity.branch
                    window: (window-target $identity)
                    window_name: $identity.window
                }]
            }
        } | flatten
    } | flatten
}

# The states in which a worker still has work in flight, and its directory is
# therefore nobody else's.
#
# NOT the terminal set. `complete` is where the leftovers actually came from: a
# worker reports, nobody accepts, and its tree lives forever — 26 of the 29
# trees in this repo were `complete`. A worker that has reported is done with
# its files; what it is waiting for is a decision, and a decision does not need
# a directory. `failed` and `protocol_error` are the same: reported and
# waiting on a person.
#
# The consequence, stated rather than hidden: sweeping a reported-but-unaccepted
# worker means a later `accept` finds no tree to reclaim. That is why this is a
# verb an operator runs when a round of work is done with, and never something
# `stop` or `result` does on its own.
const WORKING_STATES = ["created" "running" "waiting_human" "blocked"]

# Every directory a live process is currently sitting in.
#
# The bus says what a worker REPORTED; this says what is actually running, and
# the two disagree in the case that cost real work: a worker at `complete` has
# reported and been forgotten, but its pi process keeps running until something
# kills its window. Sweeping its tree deleted the directory out from under a
# live process (observed: pids 1790504 and 1927259 in wk-timestamp-md.0 and .1).
#
# /proc is Linux-only. Elsewhere this returns nothing and the bus and dirty
# guards carry the sweep on their own — a missing probe must not read as
# "nothing is running", so the caller is told which guards it got.
def cwds-in-use []: nothing -> list<string> {
    if not ("/proc" | path exists) { return [] }
    ls /proc
    | get name
    | where {|d| ($d | path basename) =~ '^[0-9]+$' }
    | each {|d|
        # A pid that exits mid-scan, or one owned by another user, answers with
        # an error rather than a path. Neither is a finding.
        let link = (do { ^readlink ($d | path join "cwd") } | complete)
        if $link.exit_code == 0 { [($link.stdout | str trim)] } else { [] }
    }
    | flatten
    | uniq
}

# Every worker window tmux is holding open for a process that has exited.
#
# `spawn` sets `remain-on-exit on` deliberately: a crashed worker's error stays
# on screen instead of vanishing with its pane. Nothing ever reaps those, so
# they accumulate — 23 dead worker windows were listed in this repo's session
# group, one round of smoke tests' worth. A sweep is the moment to take them:
# the process is gone, and the only thing lost is text nobody is reading any
# more.
#
# Returns {dead, live} window ids. tmux being unreachable is neither, and the
# caller reports it rather than treating silence as "no windows".
def worker-window-corpses [
    windows: list<string>
    socket: string
    # The projects this repo's workers actually used, read off their window
    # names (`<role>-<subject>@<project>`). A dead window that is shaped like a
    # worker's in one of those projects but has no identity on the bus is
    # REPORTED and never killed: without a bus record there is no evidence it
    # is this repo's, and a session group can be shared. No claims means no
    # known project, and then nothing is reported rather than guessed at.
    projects: list<string> = []
]: nothing -> record {
    let listed = (do { ^tmux ...(tmux-args $socket) list-windows -a -F "#{window_id}\t#{pane_dead}\t#{window_name}" } | complete)
    if $listed.exit_code != 0 { return {dead: [], live: [], orphaned: [], reachable: false} }
    # Deduplicated by id, because a grouped session lists its windows once per
    # MEMBER: this repo's group has eleven, so a first cut reported 242 windows
    # to reap where there were 22, and would have said `kill` eleven times for
    # each of them.
    let rows = (
        $listed.stdout
        | lines
        | each {|l| $l | split row "\t" }
        | where {|p| ($p | length) >= 2 }
        | each {|p| {
            id: ($p | first | str trim)
            dead: (($p | get 1 | str trim) == "1")
            name: ($p | get 2 | str trim)
        } }
        | uniq-by id
    )
    let suffixes = ($projects | each {|p| $"@($p)" })
    {
        dead: ($rows | where {|r| $r.dead and $r.id in $windows } | get id)
        live: ($rows | where {|r| (not $r.dead) and $r.id in $windows } | get id)
        orphaned: (
            $rows
            | where {|r|
                let ours = ($r.id in $windows)
                let shaped = ($suffixes | any {|sfx| $r.name | str ends-with $sfx })
                $r.dead and (not $ours) and $shaped
            }
            | select id name
        )
        reachable: true
    }
}

# Sweep worker branches off a remote.
#
# A worker that pushes its branch leaves a ref behind, and the local sweep
# cannot see it: origin carried wk-timestamp-file.2/.3/.4 and wk-timestamp-md.3
# long after every local trace was gone, and `.4` belonged to a worktree this
# machine never had.
#
# Opt-in per call, and never a side effect of the local sweep, because this is
# the one part of reclaim that reaches past this machine: a ref on a shared
# remote may be the only copy of work, or another person's checkout's upstream.
#
# `git fetch` first, always. The merged check needs the objects, and answering
# it from stale local knowledge is how a sweep deletes a ref whose new commits
# it never saw. A remote that cannot be reached is REPORTED as such (adr0017):
# an empty answer from a probe that never ran would read as a clean remote.
def remote-reclaim [
    repo: string
    remote: string
    base: string
    held: list<record>      # workers with work in flight, from the bus
    force: bool
    dry_run: bool
]: nothing -> record {
    let fetched = (do { ^git -C $repo fetch --quiet --prune $remote } | complete)
    if $fetched.exit_code != 0 {
        return {reachable: false, deleted: [], kept: [{branch: "", reason: $"could not reach ($remote): ($fetched.stderr | str trim)"}]}
    }
    # Every head, filtered HERE. Asking ls-remote for `refs/heads/wk-*` would
    # filter server-side and leave the scope guard below unexercised — a
    # mutation that deleted it kept the whole suite green. One guard that is
    # tested beats two where the tested one hides the other.
    let listed = (do { ^git -C $repo ls-remote --heads $remote } | complete)
    if $listed.exit_code != 0 {
        return {reachable: false, deleted: [], kept: [{branch: "", reason: $"could not list ($remote): ($listed.stderr | str trim)"}]}
    }
    # Only `wk-` refs are listed for, because a remote holds branches from
    # every machine and every person who pushes to it.
    let refs = (
        $listed.stdout
        | lines
        | each {|l| $l | split row "\t" }
        | where {|p| ($p | length) >= 2 }
        | each {|p| {sha: ($p | first | str trim), branch: (($p | get 1) | str replace "refs/heads/" "" | str trim)} }
        | where {|r| $r.branch | str starts-with $BRANCH_PREFIX }
    )

    mut deleted = []
    mut kept = []
    for r in $refs {
        let owner = ($held | where branch == $r.branch)
        if ($owner | is-not-empty) {
            let o = ($owner | first)
            $kept = ($kept | append {branch: $r.branch, reason: $"($o.run)/($o.uid) is ($o.state)"})
            continue
        }
        # Against the REMOTE base, not the local one: what matters is whether
        # the remote already holds these commits somewhere it will keep them.
        let target = $"refs/remotes/($remote)/($base)"
        let merged = (do { ^git -C $repo merge-base --is-ancestor $r.sha $target } | complete | get exit_code) == 0
        if not $merged and not $force {
            $kept = ($kept | append {branch: $r.branch, reason: $"not merged into ($remote)/($base); --force to delete it anyway"})
            continue
        }
        if not $dry_run {
            let pushed = (do { ^git -C $repo push --quiet $remote --delete $r.branch } | complete)
            if $pushed.exit_code != 0 {
                $kept = ($kept | append {branch: $r.branch, reason: ($pushed.stderr | str trim)})
                continue
            }
        }
        $deleted = ($deleted | append $r.branch)
    }
    {reachable: true, deleted: $deleted, kept: $kept}
}

# Reclaim every worker worktree in a project that no live worker owns.
#
# `worker-stop` leaves the tree and the branch behind deliberately: they may
# hold unmerged commits, and a stopped worker's directory is the only place to
# look at what it did. That is the right default per WORKER and the wrong one
# per PROJECT — a round of smoke tests left 29 trees and 953 MB of them in this
# repo before anything swept, and every one of those workers was resumable from
# its session id the whole time. This is the project-scoped sweep: it takes the
# directories, and what survives is the identity envelope on the bus, which is
# where the session id lives.
#
# Four reasons to keep something, in the order a reader cares about:
#
#   live      a worker with work in flight owns it — created, running,
#             waiting_human or blocked
#   in use    some process is sitting in the directory, whatever the bus says
#   locked    someone held it deliberately
#   dirty     uncommitted work, which nothing here licenses deleting
#   unmerged  commits the base does not have (the DIRECTORY still goes; a
#             worktree is re-creatable from a branch, commits are not
#             re-creatable from anything)
#
# `--force` overrides dirty and unmerged and nothing else. A tree that a live
# worker owns or that a process is sitting in is never swept, whatever the flag
# says: the flag means "I know what is in these files", which is not a claim
# anyone can make about a running process.
export def worktrees-reclaim [
    --repo: string
    # The branch a commit must be in to count as merged. Defaults to whatever
    # the main worktree is on, which is the branch work lands in.
    --base: string = ""
    --socket: string = ""
    # The remote to sweep worker branches off, e.g. `origin`. Absent means the
    # sweep stays on this machine: deleting a shared ref is the one thing here
    # that reaches past it, so it is asked for explicitly every time.
    --remote: string = ""
    --force
    --dry-run
]: nothing -> record {
    let repo = (expand-path $repo)
    let main = (main-worktree $repo)
    let base = (if ($base | is-not-empty) { $base } else {
        do { ^git -C $main rev-parse --abbrev-ref HEAD } | complete | get stdout | str trim
    })
    let trees_dir = (worktrees-dir $repo)
    let claims = (bus-claims $repo)
    let held = ($claims | where state in $WORKING_STATES)
    let in_use = (cwds-in-use)

    # Only ours: under .worktrees/, on a `wk-` branch, and not the main tree. A
    # worktree a person made for their own reasons is not a sweep's business.
    let mine = (
        registered-worktrees $repo
        | where {|w|
            let path = (expand-path $w.path)
            let ours = ($path | str starts-with $"($trees_dir)/")
            $path != $main and $ours and ($w.branch | str starts-with $BRANCH_PREFIX)
        }
    )

    mut removed = []
    mut kept = []
    mut branches_deleted = []
    mut branches_kept = []

    for w in $mine {
        let path = (expand-path $w.path)
        let owner = ($held | where cwd == $path)
        if ($owner | is-not-empty) {
            let o = ($owner | first)
            $kept = ($kept | append {path: $path, branch: $w.branch, reason: $"($o.run)/($o.uid) is ($o.state)"})
            continue
        }
        # Anything running IN the tree, not just AT its root: a shell that has
        # cd'd into a subdirectory is using the tree just as much.
        let users = ($in_use | where {|c| $c == $path or ($c | str starts-with $"($path)/") })
        if ($users | is-not-empty) {
            $kept = ($kept | append {path: $path, branch: $w.branch, reason: $"in use: a process is running in ($users | first)"})
            continue
        }
        if $w.locked {
            $kept = ($kept | append {path: $path, branch: $w.branch, reason: "locked"})
            continue
        }
        let dirty = (($path | path exists) and (worktree-dirty? $path))
        if $dirty and not $force {
            $kept = ($kept | append {path: $path, branch: $w.branch, reason: "holds uncommitted work; --force to take it anyway"})
            continue
        }
        if not $dry_run {
            # --force on the git call only when the caller asked for it: a
            # plain remove is the second guard behind worktree-dirty?, and a
            # dirty tree git refuses is a tree this code was wrong about.
            let args = (if $force { ["--force"] } else { [] })
            let out = (do { ^git -C $repo worktree remove ...$args $path } | complete)
            if $out.exit_code != 0 {
                $kept = ($kept | append {path: $path, branch: $w.branch, reason: ($out.stderr | str trim)})
                continue
            }
        }
        $removed = ($removed | append {path: $path, branch: $w.branch, dirty: $dirty})
    }

    # The other half of the leftover: a branch whose directory is already gone.
    # Allocation steps past those refs rather than reusing them, so they pile up
    # silently and nothing ever names them.
    let swept_paths = ($removed | get path)
    let still_registered = (
        registered-worktrees $repo
        | where {|w| (expand-path $w.path) not-in $swept_paths }
        | get branch
    )
    let candidates = (
        known-branches $repo
        | where {|b| $b | str starts-with $BRANCH_PREFIX }
        | where {|b| $b not-in $still_registered }
        | where {|b| $b not-in ($held | get branch) }
    )
    for b in $candidates {
        let merged = (do { ^git -C $repo merge-base --is-ancestor $b $base } | complete | get exit_code) == 0
        if not $merged and not $force {
            $branches_kept = ($branches_kept | append {branch: $b, reason: $"not merged into ($base); --force to delete it anyway"})
            continue
        }
        if not $dry_run {
            let flag = (if $merged { "-d" } else { "-D" })
            let out = (do { ^git -C $repo branch $flag $b } | complete)
            if $out.exit_code != 0 {
                $branches_kept = ($branches_kept | append {branch: $b, reason: ($out.stderr | str trim)})
                continue
            }
        }
        $branches_deleted = ($branches_deleted | append $b)
    }

    if not $dry_run { do { ^git -C $repo worktree prune } | complete | ignore }

    # Windows are swept for THIS repo's workers only, by window id from their
    # identity envelopes. Matching on the name instead would reach into another
    # project's session group, where a same-named window is somebody else's.
    let ours = ($claims | where {|c| $c.cwd == $repo or ($c.cwd | str starts-with $"($repo)/") })
    let corpses = (
        worker-window-corpses
            ($ours | get window | where {|w| $w | str starts-with "@" })
            $socket
            (
                $ours
                | get window_name
                | where {|n| $n | str contains "@" }
                | each {|n| $n | split row "@" | last }
                | uniq
            )
    )
    mut windows_killed = []
    mut windows_kept = []
    for id in $corpses.dead {
        if not $dry_run {
            let out = (do { ^tmux ...(tmux-args $socket) kill-window -t $id } | complete)
            if $out.exit_code != 0 {
                $windows_kept = ($windows_kept | append {window: $id, reason: ($out.stderr | str trim)})
                continue
            }
        }
        $windows_killed = ($windows_killed | append $id)
    }
    # A live window is named rather than silently skipped: after a tree has
    # been swept, a still-running worker in it is exactly what an operator
    # needs to know about.
    for id in $corpses.live {
        let owner = ($ours | where window == $id | first)
        $windows_kept = ($windows_kept | append {window: $id, reason: $"($owner.run)/($owner.uid) is still running"})
    }
    # Named, never killed. A bus record is what proves a window is this
    # project's; without one the sweep can only tell the operator it is there.
    for w in $corpses.orphaned {
        $windows_kept = ($windows_kept | append {window: $w.id, reason: $"dead, but no identity on the bus for it \(($w.name)); kill it by hand"})
    }

    let remote_swept = (if ($remote | is-empty) {
        {reachable: true, deleted: [], kept: []}
    } else {
        remote-reclaim $repo $remote $base $held $force $dry_run
    })

    {
        repo: $repo
        base: $base
        dry_run: $dry_run
        removed: $removed
        kept: $kept
        branches_deleted: $branches_deleted
        branches_kept: $branches_kept
        windows_killed: $windows_killed
        windows_kept: $windows_kept
        tmux_reachable: $corpses.reachable
        remote: $remote
        remote_deleted: $remote_swept.deleted
        remote_kept: $remote_swept.kept
        remote_reachable: $remote_swept.reachable
    }
}

# --------------------------------------------------------------- identity
#
# The identity envelope is what ties a worker UID to the worktree it runs in,
# the Pi session that can resume it, and the tmux window that displays it. It
# lives under `state-root` (sp029 T6), NOT inside the worktree and NOT on the
# runtime bus, so it outlives both cleanup AND a logout: an accepted worker
# whose directory is gone, in a session that has long since ended, must still
# be resumable from its session id.

export def bus-identity [uid: string, --run: string, --identity: record]: nothing -> record {
    validate-identity $identity
    # Still claims the runtime worker directory, unchanged: that is the
    # occupied-address guard `worker-spawn` checks BEFORE ever calling this,
    # and `bus-send`/`bus-result` still address inbox/outbox there too — this
    # task moves the placement record, not the legacy message tree.
    ensure-worker-dirs $run $uid
    let slug = (resolve-project-slug $identity.cwd)
    ensure-state-dirs $slug $run $uid
    let dir = (agent-state-dir $slug $run $uid | path join "identity")
    ensure-dir $dir
    let sealed = (claim-slot $dir (envelope-for $run $uid "identity" $identity))
    # Recorded AFTER the write succeeds: a caller resolving `(run, uid)` back
    # to a slug must never find a pointer to a record that is not there yet.
    record-agent-slug $run $uid $slug
    $sealed
}

# The worker's current identity ENVELOPE, or nothing if none was recorded.
#
# Separate from `bus-identity-of` because the envelope carries the `created`
# stamp and the payload does not. That stamp is the only record of when a
# worker was spawned, so anything asking "how long has this been running"
# needs the envelope rather than what is inside it.
export def bus-identity-envelope [uid: string, --run: string]: nothing -> any {
    let dir = (identity-log-dir $run $uid)
    if $dir == null { return null }
    let records = (read-box $dir)
    if ($records | is-empty) { return null }
    $records | last
}

# The worker's current identity, or nothing if it was never recorded.
export def bus-identity-of [uid: string, --run: string]: nothing -> any {
    let envelope = (bus-identity-envelope $uid --run $run)
    if $envelope == null { return null }
    $envelope | get payload
}

# ------------------------------------------------------- v1 import (sp029 T6)
#
# v1 wrote identity under the RUNTIME bus tree
# ($XDG_RUNTIME_DIR/pi-worker/<run>/<uid>/identity), which is wiped at logout.
# A worktree it names can outlive that wipe, so this is the one-way bridge
# onto durable storage for whatever v1 identity is still sitting on the bus
# when this lands.
#
# Keyed by each record's own `cwd`, not by `(run, uid)`: a v1 uid was only
# ever unique within its OWN run, so two independent runs may have minted the
# same uid for two different worktrees, and importing by uid alone would let
# the second overwrite the first's placement record without either side ever
# refusing. `cwd` is what `accept`/`reclaim` actually act on, and only one
# live worktree can hold it.
#
# Idempotent by construction rather than by a separate ledger: a `(run, uid)`
# that already resolves a slug was either imported by a previous call or
# written natively, and either way there is nothing left for THIS call to do.
# The import reads v1 BYTES, so it carries its own reader rather than going
# through `read-box`. `read-box` calls `validate-envelope`, which is the v2
# gate: it requires `from`/`to`/`content` and refuses `protocol: 1` outright.
# That refusal is correct and must stay — a v2 reader acting on a v1 message
# is exactly the confusion the version field exists to prevent — but it is
# also, literally, a refusal to read the only thing this bridge exists to
# read. The two requirements are not in conflict once they stop sharing one
# validator: the bus gate keeps refusing v1, and the import validates the v1
# shape it actually expects.
#
# That shape is what the shipped v1 writer produced (`envelope-for` before
# sp029 T2): `{protocol: 1, sequence, run, uid, kind, created, payload}` —
# no `from`, no `to`, no `content`. Anything else in a legacy identity dir is
# named and refused, never coerced: a record this build cannot account for is
# a record an operator has to look at, and the alternative (skip it) loses a
# placement whose worktree may still be occupied.
const V1_PROTOCOL = 1
const V1_IDENTITY_REQUIRED = ["protocol" "run" "uid" "kind" "created" "payload"]

def validate-v1-identity-envelope [envelope: record] {
    let fields = ($envelope | columns)

    # Version FIRST, then shape: which fields are required is itself a
    # function of the version, so "missing required field 'run'" is a
    # misleading thing to say about a v2 record that never had one.
    if "protocol" not-in $fields {
        error make {msg: "v1 identity envelope is missing required field 'protocol'"}
    }
    if $envelope.protocol != $V1_PROTOCOL {
        error make {msg: $"expected a v1 identity envelope \(protocol ($V1_PROTOCOL)), got protocol ($envelope.protocol): the import bridges v1 records only, and this build writes v($PROTOCOL_VERSION) natively"}
    }

    for required in $V1_IDENTITY_REQUIRED {
        if $required not-in $fields {
            error make {msg: $"v1 identity envelope is missing required field '($required)'"}
        }
    }

    if $envelope.kind != "identity" {
        error make {msg: $"expected a v1 envelope of kind 'identity', got '($envelope.kind)'"}
    }

    if not (($envelope.payload | describe) | str starts-with "record") {
        error make {msg: $"v1 identity payload must be a record, got ($envelope.payload | describe)"}
    }

    # The same field set `bus-identity` enforces on write, so a record that
    # passes here is one the durable writer will accept unchanged.
    validate-identity $envelope.payload
}

# `read-box` for v1 identity logs. Fails closed for the same reason it does:
# a named file an operator can fix beats a placement that quietly vanished.
def read-v1-identity-box [dir: string]: nothing -> list<record> {
    if not ($dir | path exists) { return [] }
    let files = (
        ls $dir
        | get name
        | where {|n| ($n | path basename | str ends-with ".json") }
        | sort-by {|n| $n | path basename | str replace ".json" "" | into int }
    )

    # `for`, not `each`, for the reason spelled out over `read-box`: nushell
    # 0.115 swallows an `error make` raised inside an `each` closure.
    mut envelopes = []
    for n in $files {
        let raw = (open --raw $n)
        let parsed = (try { $raw | from json } catch {
            error make {msg: $"unparseable v1 identity ($n | path basename) in ($dir): the import fails closed rather than skipping a placement record"}
        })
        if not (($parsed | describe) | str starts-with "record") {
            error make {msg: $"unparseable v1 identity ($n | path basename) in ($dir): expected a JSON object, got ($parsed | describe)"}
        }
        try { validate-v1-identity-envelope $parsed } catch {|e|
            error make {msg: $"invalid v1 identity ($n | path basename) in ($dir): ($e.msg)"}
        }
        $envelopes = ($envelopes | append $parsed)
    }
    $envelopes
}

export def import-v1-identities []: nothing -> record {
    let root = (bus-root)
    if not ($root | path exists) {
        return {imported: [], already: []}
    }

    # Nested `for` rather than nested `each`, for the reason the NOTE ON THE
    # LOOP over `read-box` documents: an `error make` raised inside an `each`
    # closure does not surface as itself. Here it does not vanish outright —
    # the outer pipeline still fails — but it arrives as the bare "Eval block
    # failed with pipeline input", losing the named file and named reason the
    # reader went to the trouble of producing. An operator cannot fix a record
    # the refusal will not name.
    mut found = []
    for run_dir in (ls $root | where type == dir | get name) {
        let run = ($run_dir | path basename)
        for worker_dir in (ls $run_dir | where type == dir | get name) {
            let uid = ($worker_dir | path basename)
            let records = (read-v1-identity-box ($worker_dir | path join "identity"))
            if ($records | is-not-empty) {
                $found = ($found | append {run: $run, uid: $uid, payload: ($records | last | get payload)})
            }
        }
    }

    if ($found | is-empty) {
        return {imported: [], already: []}
    }

    # Every refusal collected BEFORE anything is touched — the same
    # discipline `worktree-cleanup-guard` uses, and for the same reason: an
    # import is not the moment to guess which of two conflicting records is
    # the real one.
    let cwds = ($found | get payload.cwd | uniq)
    mut conflicts = []
    for cwd in $cwds {
        let group = ($found | where {|r| $r.payload.cwd == $cwd })
        if ($group | length) > 1 {
            let names = ($group | each {|r| $"($r.run)/($r.uid)" } | str join " and ")
            $conflicts = ($conflicts | append $"($names) both hold an identity for cwd ($cwd)")
        }
    }
    if ($conflicts | is-not-empty) {
        error make {msg: $"refusing to import v1 identities: ($conflicts | str join '; '). Remove the one that is not current by hand and import again"}
    }

    mut imported = []
    mut already = []
    for rec in $found {
        if (resolve-agent-slug $rec.run $rec.uid) != null {
            $already = ($already | append {run: $rec.run, uid: $rec.uid})
            continue
        }
        bus-identity $rec.uid --run $rec.run --identity $rec.payload
        # Never silently dropped: a worktree that no longer exists is still
        # imported as a record, with that fact named rather than hidden.
        $imported = ($imported | append {
            run: $rec.run
            uid: $rec.uid
            cwd: $rec.payload.cwd
            worktree_exists: ($rec.payload.cwd | path exists)
        })
    }
    {imported: $imported, already: $already}
}

# ====================================================== visible Pi workers
#
# A worker is a Pi process in a named tmux window inside the existing linked
# project group. tmux's ONLY jobs here are to display the process and to keep
# it alive; see the transport-boundary note at the top of this file. Spawning
# uses `new-window` and liveness uses `list-windows` — no send-keys, no
# wait-for, no pane options.


# Expand a path argument before anything is done with it.
#
# An agent driving this tool writes `~/.dotfiles`, because that is how a human
# writes it. Nothing on the way to git expands a tilde, so it used to arrive
# literally and fail with "cannot change to '~/.dotfiles'" — a confusing error
# for an argument that looks correct. Expanding once, at the edge, keeps every
# interior path absolute.
export def expand-path [path: string]: nothing -> string {
    if ($path | is-empty) { $path } else { $path | path expand }
}

# The main worktree of a repo — where a stage declared isolation=main runs,
# and the anchor `project-dir` slugs so a `wk-*` worker addresses the same
# project as its initiator.
#
# Reads `git rev-parse --git-common-dir` rather than parsing `worktree list`:
# every worktree of one repo — main or linked — shares the same common dir,
# so its PARENT is the main worktree regardless of which worktree asked, and
# unlike `worktree list --porcelain` this is correct even when a worktree's
# `.git` is a FILE pointing elsewhere rather than a directory (every linked
# worktree's `.git` is a file; only the main worktree's is a directory).
# `worktree list` was tried first and rejected: for a submodule its own first
# entry names the internal `.git/modules/<name>` gitdir, not the working
# directory, so parsing it would have slugged a path nothing ever `cd`s into.
#
# A submodule or a bare repo has no common dir shaped `<worktree>/.git` — a
# bare repo has none at all (`current-repo` already refuses that case before
# this runs), and a submodule's is `<parent>/.git/modules/<name>`. Neither is
# a "linked worktree of another checkout" in the sense this function resolves,
# so both fall back to the repo path they were given: for a submodule that IS
# already its own main (and only) worktree.
export def main-worktree [repo_in: string]: nothing -> string {
    let repo = (expand-path $repo_in)
    let common = (do { ^git -C $repo rev-parse --path-format=absolute --git-common-dir } | complete)
    if $common.exit_code != 0 {
        error make {msg: $"cannot resolve the git directory for ($repo): ($common.stderr | str trim)"}
    }
    let common_dir = ($common.stdout | str trim)
    if ($common_dir | str ends-with "/.git") {
        $common_dir | path dirname
    } else {
        $repo
    }
}

# Where a worker runs, and on which branch.
#
# `--isolation` is required and typed by the caller directly (sp029 T8) — no
# default, and no stage-name lookup to a registry decides it for them:
#
#   isolation=worktree  its own throwaway `wk-<subject>.<N>` worktree and
#                       branch, so concurrent workers never share a tree
#   isolation=main      the repo's main worktree on the default branch, and no
#                       task branch — for work whose tooling refuses to run
#                       anywhere else, or whose writes belong on the canonical
#                       branch
#
# `main` means the worker shares a tree with the operator and with every other
# such worker, so the CALLER that asks for it owns the serialisation problem.
export def worker-placement [
    --repo: string
    --isolation: string
    --subject: string
]: nothing -> record {
    let repo = (expand-path $repo)
    if ($isolation | default "") not-in $ISOLATIONS {
        error make {msg: $"--isolation must be one of ($ISOLATIONS | str join ', '), got '($isolation)': nothing may land in the main worktree without that word being typed"}
    }
    if $isolation == "main" {
        let main = (main-worktree $repo)
        let branch = (^git -C $main rev-parse --abbrev-ref HEAD | str trim)
        return {path: $main, branch: $branch, isolated: false}
    }

    let tree = (worktree-allocate --repo $repo --task $subject)
    {path: $tree.path, branch: $tree.branch, isolated: true}
}

# The tmux session to create a worker's window in, given a project name.
#
# dotfiles-k5vt: `--project` is documented as a session GROUP, and that is the
# right model — grouped sessions share windows, so a worker window created in
# any member appears in all of them, and `<role>-<subject>@<group>` is what an
# operator scans a window list for. But `tmux -t` neither resolves groups nor
# matches them: it PREFIX-matches session names. So `-t dotfiles` against a
# group holding `dotfiles_7` alone matches by accident and looks correct, while
# the same command against `dotfiles_3 .. dotfiles_36` is ambiguous and fails
# with "can't find window: dotfiles" — which is what the live run hit.
#
# Accidental prefix uniqueness is worse than an outright failure: it works
# until the operator opens a second view. So the group is resolved explicitly.
#
# An exact session name wins over a group of the same name: it is unambiguous,
# and it is what an operator reaches for to pin one view out of many.
export def resolve-project-session [project: string, --socket: string = ""] {
    let listed = (do { ^tmux ...(tmux-args $socket) list-sessions -F "#{session_name}\t#{session_group}" } | complete)
    if $listed.exit_code != 0 {
        error make {msg: $"cannot list tmux sessions: ($listed.stderr | str trim)"}
    }

    let sessions = (
        $listed.stdout
        | lines
        | each {|l| $l | split row "\t" }
        | where {|r| ($r | length) >= 1 and (($r | first | str trim) | is-not-empty) }
        | each {|r| {name: ($r | first | str trim), group: (if ($r | length) >= 2 { $r | get 1 | str trim } else { "" })} }
    )

    let exact = ($sessions | where name == $project)
    if ($exact | is-not-empty) { return ($exact | first | get name) }

    # Any member will do — grouped sessions share their window list, so the
    # window appears in every view either way. Sorted for determinism: the same
    # project must resolve to the same session across calls.
    let members = ($sessions | where group == $project | sort-by name)
    if ($members | is-not-empty) { return ($members | first | get name) }

    error make {msg: $"no tmux session or session group named '($project)'. Known sessions: ($sessions | get name | sort | str join ', ')"}
}

# Turn whatever the caller called the work into something that can be a name.
#
# A subject is worn as a tmux window name AND a git branch, so it has to be a
# name in both. Observed live, window @234 in this repo's session group:
#
#     impl-Create timestamp-named text file with header in
#     /home/jan/.dotfiles. Filename must be safe.@dotfiles
#
# An agent had passed its whole instruction as --subject. The window list
# became unreadable, and `.` and `/` are hostile in a ref — worktree-allocate
# spent 64 attempts failing to build a branch out of prose and then reported
# that git had refused, which is the truth at the wrong altitude entirely.
#
# Slugified rather than refused, and that is a change of policy: the earlier
# code refused prose outright on the grounds that truncating produces an
# address named after the first few words of an instruction. It does — and an
# orchestrator stopped mid-round by a cosmetic complaint about a window name is
# worse. The address is for finding the worker; the instructions carry the
# meaning, and they travel in the message either way.
#
# Everything outside [a-z0-9] becomes a separator, runs collapse, and the cut
# to MAX_SUBJECT_CHARS never leaves one trailing. A subject with nothing usable
# in it is still refused: slugifying is not a licence to invent an address, and
# a worker called `impl-@dotfiles` is worse than being told.
export def slugify-subject [subject: string]: nothing -> string {
    let cleaned = (
        $subject
        | str lowercase
        | str replace --all --regex '[^a-z0-9]+' "-"
        | str trim --char "-"
    )
    # Cut at a word boundary. A hard cut at the character limit produced
    # `create-timestamp-named-text-file-with-he`, and a name is meant to be
    # read.
    #
    # The fitter STOPS at the first word that does not fit rather than skipping
    # it: taking every word that happens to fit turned "...text file with
    # header in /home/jan/.dotfiles" into `...-file-with-in`, welding `in` onto
    # `with` across the `header` it had dropped. A name assembled from
    # non-adjacent words says something the caller did not.
    let fitted = (
        $cleaned
        | split row "-"
        | reduce --fold {text: "", full: false} {|word, acc|
            if $acc.full { $acc } else {
                let candidate = (if ($acc.text | is-empty) { $word } else { $"($acc.text)-($word)" })
                if ($candidate | str length) <= $MAX_SUBJECT_CHARS {
                    {text: $candidate, full: false}
                } else {
                    {text: $acc.text, full: true}
                }
            }
        }
        | get text
    )
    # Empty means the very first word is longer than the whole budget: there is
    # no boundary to find, so it is cut hard.
    let slug = (
        if ($fitted | is-empty) { $cleaned | str substring 0..($MAX_SUBJECT_CHARS - 1) } else { $fitted }
        | str trim --char "-"
    )
    if ($slug | is-empty) {
        error make {msg: $"'($subject)' has no usable characters for a name, and it has to be one: a subject is worn as a tmux window name and a git branch. Pass a slug like 'timestamp-file'; what the worker should DO belongs in the message"}
    }
    $slug
}

# The name an operator scans a window list for: `<role>-<subject>@<project>`.
# Subject is the ticket id for ticket-payload stages and the artifact id otherwise.
export def worker-window-name [role: string, subject: string, project: string]: nothing -> string {
    $"($role)-($subject)@($project)"
}

def tmux-args [socket: string]: nothing -> list<string> {
    if ($socket | is-empty) { [] } else { ["-L" $socket] }
}

# What can be observed about a worker's process, as one of three verdicts.
#
# dotfiles-yii5: this probe used to match on the window NAME alone and return a
# bool. But spawn sets `remain-on-exit on` deliberately — a crashed worker's
# window stays listed so its error stays on screen — so a worker whose process
# died at startup still had its name in the list, and the tool reported it
# healthy. Every worker was dead for the whole of the dotfiles-4xtz bug while
# `live: true` came back each time.
#
# adr0017 dictates the shape. "I cannot tell" is a first-class verdict, distinct
# from "it is dead", and absence of evidence must never be encoded as evidence
# of absence. A bool cannot carry both, so:
#
#   live     the pane exists and its process is running
#   exited   the pane exists and its process is gone — the worker's OWN
#            evidence about ITSELF, and therefore reportable
#   gone     tmux answered, and there is no such window
#   unknown  tmux could not be reached — nobody watched, so nothing was
#            observed
#
# `gone` and `unknown` were one verdict, and that was the bug adr0017 exists to
# prevent: "sharing a code between 'dead' and 'cannot tell' is precisely the
# bug this prevents". A worker whose window had been reaped read the same as
# one on a box where tmux was down, and since `unknown` correctly never
# licenses cleanup, it sat at `running` forever. Splitting them makes
# `running`/`gone` legible as "died without reporting" — the case that needs a
# human — where before it was indistinguishable from "ask again later".
#
# `unknown` and `gone` are both OBSERVATIONAL verdicts: never persisted, never
# reportable by a worker about itself. Neither licenses automatic cleanup —
# `gone` is tmux's evidence about a window, not the worker's about its work,
# and adr0017 reserves automatic recovery for the latter. So `gone` is
# REPORTED, and a human decides.
#
# Nor is `exited` a licence — knowing a process stopped is not knowing the work
# is finished.
export def worker-liveness [window: string, --socket: string = ""]: nothing -> record {
    # A window_id (@N) is matched exactly; a name is matched as before, so an
    # identity written before ids were recorded is still addressable rather than
    # stranded.
    let by_id = ($window | str starts-with "@")
    let fmt = (if $by_id { "#{window_id}\t#{pane_dead}" } else { "#{window_name}\t#{pane_dead}" })
    let listed = (do { ^tmux ...(tmux-args $socket) list-panes -a -F $fmt } | complete)
    # A caller that could not reach tmux has learned nothing about the worker.
    # Reporting "exited" here would be the caller's failure misattributed to the
    # component — the exact confusion adr0017 forbids.
    if $listed.exit_code != 0 {
        return {verdict: "unknown", window: $window, reason: "tmux could not be reached"}
    }

    let panes = (
        $listed.stdout
        | lines
        | each {|l| $l | split row "\t" }
        | where {|p| ($p | length) >= 2 and (($p | first | str trim) == $window) }
    )
    if ($panes | is-empty) {
        # tmux ANSWERED. That the window is absent is a finding, not a failure
        # to observe, and calling it `unknown` threw that away.
        return {verdict: "gone", window: $window, reason: "tmux has no such window; it was closed or reaped"}
    }

    # Grouped sessions list the same window once per session, so a window may
    # appear several times. Any live pane means the worker is running.
    let any_alive = ($panes | any {|p| ($p | get 1 | str trim) != "1" })
    if $any_alive {
        {verdict: "live", window: $window, reason: "its process is running"}
    } else {
        {verdict: "exited", window: $window, reason: "the window remains but its process is gone"}
    }
}

# Whether a worker is OBSERVABLY RUNNING.
#
# Strictly `verdict == "live"`. Both other verdicts are false, and callers must
# not read that false as permission to clean anything up: "exited" and "unknown"
# mean different things, and only `worker-liveness` can tell them apart.
export def worker-live? [window: string, --socket: string = ""]: nothing -> bool {
    (worker-liveness $window --socket $socket | get verdict) == "live"
}

# How to address a worker's window: its id when one was recorded, its name
# otherwise. Callers use this rather than reaching for identity.window, so an
# older identity keeps working and a newer one is never addressed ambiguously.
export def window-target [identity: record]: nothing -> string {
    let id = ($identity | get -o window_id | default "")
    if ($id | is-empty) { $identity.window } else { $id }
}

# Open a worker's window and protect it, and hand back its id.
#
# Shared by spawn and respawn so the two cannot drift: everything here is
# ordering that was learned the hard way, and a second copy of it would be a
# second place to get that ordering wrong.
#
# `--resume` picks the Pi session flag, and the two are NOT aliases:
# `--session <path|id>` RESUMES an existing session and exits with "No session
# found matching '<id>'" when it is absent, while `--session-id` uses that
# exact id and creates it if missing. spawn mints a fresh uuid, so the session
# cannot exist yet and the resuming flag is always wrong there; respawn
# continues a session that does exist, where creating would fork a second
# transcript under the same id. A live run against Pi 0.84.4 hit the first half
# of that: the pane died at startup while spawn still reported live: true.
def open-worker-window [
    --target: string        # the tmux session (group member) to create it in
    --name: string          # the window name an operator scans for
    --cwd: string
    --session: string
    --window-env: list<string>   # `-e` pairs, already assembled
    --socket: string = ""
    --resume                # continue an existing session rather than create one
]: nothing -> string {
    let flag = (if $resume { "--session" } else { "--session-id" })
    # `-P -F #{window_id}` makes new-window print the id it assigned. That id is
    # how every later operation addresses this worker: a NAME is ambiguous the
    # moment two runs share a role and subject, and tmux then targets whichever
    # window it finds first — which is how a stop closed the wrong worker
    # (dotfiles-idzp). An id is also free of the `.` that made a ticket-shaped
    # subject unparseable (dotfiles-pnxw).
    let created = (do {
        ^tmux ...(tmux-args $socket) new-window -d -P -F "#{window_id}" -t $target -n $name -c $cwd ...$window_env "pi" $flag $session
    } | complete)
    if $created.exit_code != 0 {
        error make {msg: $"tmux could not create window ($name): ($created.stderr | str trim)"}
    }
    let window_id = ($created.stdout | str trim)
    # FIRST, before anything slower: a worker whose command fails instantly is
    # exactly the one whose error must stay on screen, and every millisecond
    # between creating the window and setting this is a window in which a fast
    # exit destroys it and takes the reason with it.
    #
    # `remain-on-exit on` keeps a crashed or finished worker's window in place.
    # Without it a Pi that fails during startup takes its own error message off
    # the screen, and the operator is left with a missing window and no reason.
    do { ^tmux ...(tmux-args $socket) set-option -t $window_id remain-on-exit on } | complete | ignore

    # Pin the pane, or this repo's own housekeeping deletes the worker.
    #
    # `nushell/actions/tmux-cleanup` reaps unattached windows that have no pane
    # with `@pinned` set to "1", and a worker window is created with
    # `new-window -d` — detached by definition, since the whole point is that
    # the operator is working elsewhere. Observed in ~/.tmux.log:
    #
    #     04:44:52 - Killing unattached window - no pinned panes: @223
    #     04:55:39 - Killing unattached window - no pinned panes: @229
    #
    # The worker died mid-task, its window vanished, and because liveness has
    # no way to distinguish that from "tmux could not be asked", the bus left
    # it `running` forever. The operator saw a worker running for five minutes
    # with no window anywhere on the machine.
    #
    # [[poc022]] said this before sp028 shipped: "Match the existing
    # `tmux-start` group construction, identify workers through explicit pane
    # options". `tmux-start` sets `@pinned` on every pane it creates; this is
    # the same convention, applied by the one thing that also creates panes.
    #
    # Not a transport-boundary violation: `@pinned` carries no message, no
    # completion signal and no coordination state. It tells the DISPLAY host
    # not to reap a window — which is exactly the "tmux hosts and displays
    # workers" half of that rule, not the bus half.
    #
    # Set immediately after remain-on-exit, and before anything slower, for the
    # same reason: the gap between creating a window and protecting it is a gap
    # in which it can be destroyed.
    do { ^tmux ...(tmux-args $socket) set-option -p -t $window_id "@pinned" "1" } | complete | ignore
    $window_id
}

# Start a visible, resumable Pi worker.
#
# Order matters. The worktree is allocated and the identity envelope is written
# BEFORE the process starts, so a worker that dies during startup still leaves
# a resume command and a cwd behind. Evidence first, process second: the
# reverse order loses exactly the information needed to diagnose a failed
# start.
export def worker-spawn [
    --run: string
    --uid: string
    --role: string
    --subject: string
    --project: string
    --repo: string
    --task: string = ""
    --session: string
    --skill: string
    --isolation: string
    # dotfiles-uwz6: who is to be told when this worker reports. Defaults to
    # the run (see worker-place), which is exactly what every caller got
    # before this flag existed.
    --commissioner: string = ""
    --socket: string = ""
] {
    # Refused BEFORE the address is claimed and before anything is allocated:
    # a bad commissioner is a caller error detectable up front, and this guard
    # lives on `worker-spawn` rather than on the CLI wrapper for the reason
    # `slugify-subject` moved here too — every nu caller (the tests, the
    # scrum-master skill, the next verb) goes straight past the wrapper.
    if ($commissioner | is-not-empty) {
        # An address becomes a queue file name under the bus (`queue-append`),
        # so it is held to the same character set the extension's own queue
        # reader enforces before it will touch a row — and `.`/`..` are
        # refused outright rather than left to resolve as path segments.
        if not ($commissioner =~ '^[A-Za-z0-9._-]+$') or ($commissioner in [".", ".."]) {
            error make {msg: $"spawn's --commissioner is an address, not prose: '($commissioner)' must match [A-Za-z0-9._-]+. It names who is told when this worker reports — a peer's uid, or your own claimed address. Omit it and the run this spawn mints is used, which is what `wait --as <run>` reads"}
        }
        # Length, for the same reason as the character set and in the same
        # breath: the address has to BE a file name (`queue/<address>`), and
        # one that cannot be is a caller error detectable here, at spawn.
        #
        # Unbounded, it was not. A 301-character commissioner was accepted and
        # recorded verbatim; the failure surfaced at `bus-result`, where the
        # outbox envelope is written FIRST and succeeds — so `status`, `accept`
        # and `derive-state` all still see the result — and only the additive
        # peer-bus delivery throws `I/O error` (ENAMETOOLONG from
        # `queue-append`). Net effect: the worker's own `result` exits nonzero
        # while the named commissioner is never told, which is precisely the
        # silence dotfiles-uwz6 exists to end. Nothing is left half-written and
        # a retry fails identically, so the only fix is to refuse it up front.
        if ($commissioner | str length) > $MAX_ADDRESS_CHARS {
            error make {msg: $"spawn's --commissioner is an address, and an address is a file name: '($commissioner | str substring 0..31)…' is ($commissioner | str length) characters, over the ($MAX_ADDRESS_CHARS)-character cap. An address is a peer's uid or a run — `impl-2`, `r7` — not a description of one"}
        }
    }

    # An address is claimed once. Spawning onto an occupied one used to inherit
    # the previous occupant's mail: the first message got a sequence continuing
    # someone else's, `wait` returned THEIR result envelope, and a stale
    # `stopped` marker made teardown a no-op. The initiator then reported a
    # result its worker never produced, which is the worst kind of wrong — it
    # looks like success.
    #
    # Refused rather than cleared: the old envelopes may be the only record of
    # what the previous worker did, and deleting evidence to make room is not
    # this command's call.
    let existing = (worker-dir $run $uid)
    if ($existing | path exists) {
        error make {msg: $"($run)/($uid) already exists: that address has been used, and spawning onto it would inherit its mail and markers. Use a different uid, or release this one with `rm --run ($run) --uid ($uid)` once it is finished with"}
    }

    # The guard above answers for ONE run, which stopped being an answer at
    # all when sp029 T9 gave every spawn a fresh run of its own: the directory
    # it checks is empty by construction, so it can no longer fire for the
    # case it was written for (dotfiles-bg65). This one answers for the
    # project — the scope a uid is actually an address in — and claims it
    # atomically, so two spawns racing for the same lowest-free uid cannot
    # both proceed.
    claim-address $repo $uid
    # Everything downstream allocates: a worktree, a branch, a tmux window. If
    # any of it fails, nothing was spawned onto this address and holding it
    # would burn the name for no one's benefit — so the claim is released and
    # the original failure is re-raised untouched. A failure PAST the identity
    # write keeps the address anyway, and deliberately: that record is the
    # resume handle for a worker whose window never came up, and an address
    # something can still be resumed from is not free.
    let outcome = (try {
        {ok: true, value: (worker-place --run $run --uid $uid --role $role --subject $subject --project $project --repo $repo --task $task --session $session --skill $skill --isolation $isolation --commissioner $commissioner --socket $socket)}
    } catch {|e| {ok: false, error: $e} })
    if not $outcome.ok {
        release-address $repo $uid
        error make $outcome.error.raw
    }
    $outcome.value
}

# Allocate the worker itself: the tmux target, the worktree, the identity and
# the window. Split out of `worker-spawn` so the address claim above has a
# failure boundary to release on, and for no other reason — the body is
# unchanged.
def worker-place [
    --run: string
    --uid: string
    --role: string
    --subject: string
    --project: string
    --repo: string
    --task: string = ""
    --session: string
    --skill: string
    --isolation: string
    --commissioner: string = ""
    --socket: string = ""
] {
    # Fail before allocating anything if the display host is unreachable.
    let reachable = (do { ^tmux ...(tmux-args $socket) list-sessions } | complete)
    if $reachable.exit_code != 0 {
        let which = (if ($socket | is-empty) { "default" } else { $socket })
        error make {msg: $"cannot reach tmux server \(socket: ($which)): ($reachable.stderr | str trim)"}
    }

    # Resolved BEFORE anything is allocated. A wrong --project used to fail at
    # new-window, after the worktree and identity envelope had been written,
    # leaving a branch to prune by hand (hit on the first live run).
    let target = (resolve-project-session $project --socket $socket)

    # Inside worker-spawn, not in the CLI wrapper where this guard used to
    # live: every nu caller — the scrum-master skill, the tests, the next verb
    # — went straight past the wrapper, which is how prose reached a window
    # name in the first place.
    let subject = (slugify-subject $subject)
    let window = (worker-window-name $role $subject $project)
    # NOT `$task | default $subject`. `default` substitutes for null, not for an
    # empty string, so a stage with no task would have allocated a worktree
    # named `wk-.0`; worse, nushell raises on `default` applied to a plain string
    # and reports it as the entirely unrelated "External command failed", which
    # is how this sat hidden behind a passing-looking spawn.
    let subject_for_branch = (if ($task | is-empty) { $subject } else { $task })
    # Placement is decided by the caller's own --isolation, typed at spawn
    # time (sp029 T8, dotfiles-ptba).
    let tree = (worker-placement --repo $repo --isolation $isolation --subject $subject_for_branch)

    # dotfiles-uwz6: the commissioner is an ADDRESS, and the run is only its
    # default.
    #
    # sp029 T5 wired it to the run because "the run is the closest thing to a
    # resolvable address an initiator has BEFORE T7/T9 land real peer
    # addressing, so it doubles as the commissioner". T7/T9 shipped that
    # addressing — `send`/`wait` take arbitrary addresses — and this stayed a
    # pre-peer-addressing workaround inside a peer-addressed bus: an
    # orchestrator operating under its OWN address was never told anything,
    # silently, because mail addressed elsewhere is not an error, and the
    # natural next move is to poll `ps` — which is what the bus exists to make
    # unnecessary. `respawn` already carried a prior commissioner forward, so
    # the field was never assumed to equal the run.
    #
    # Defaulting to the run keeps every existing caller on exactly today's
    # behavior. A future self-registering agent (T7) never goes through
    # worker-spawn at all, so it never gets this field — which is what leaves
    # it uncommissioned by the same absent-key convention bus-settled reads.
    let commissioner = (if ($commissioner | is-empty) { $run } else { $commissioner })

    # dotfiles-v13r: `task` is the ticket this worker serves, RECORDED rather
    # than merely consumed by `subject_for_branch` above. The branch cannot
    # answer for it — `wk-foo.0` is identical whether `foo` arrived as a ticket
    # id or as a plain subject — so without this the association between a
    # worker and its bd issue survived only in whatever the dispatcher
    # remembered or in the free-text briefing in its inbox, which is exactly
    # the recovery hole ft014's "rebuild a worker's state from its durable
    # identity record" claim did not cover. Empty when no ticket was named:
    # absent, never substituted.
    bus-identity $uid --run $run --identity {
        role: $role
        cwd: $tree.path
        branch: $tree.branch
        session: $session
        skill: $skill
        isolation: $isolation
        window: $window
        task: $task
        commissioner: $commissioner
    }

    # The worker's identity reaches the extension as environment, not as a
    # message: the extension needs to know which inbox is its own BEFORE any
    # message can be delivered, and a bootstrap message would have nowhere to
    # arrive. `new-window -e` sets these on the window's own environment only,
    # so nothing leaks into the operator's other windows.
    # A worker sharing the operator's tree is stopped from committing to it;
    # see write-commit-guard. An isolated worker owns its branch and must be
    # able to commit, so it gets nothing here.
    let commit_guard = (if not $tree.isolated {
        let hooks = (write-commit-guard $run $uid $skill $tree.branch)
        [
            "-e" "GIT_CONFIG_COUNT=1"
            "-e" "GIT_CONFIG_KEY_0=core.hooksPath"
            "-e" $"GIT_CONFIG_VALUE_0=($hooks)"
        ]
    } else { [] })

    # dotfiles-v13r: the ticket travels into the window with the rest of the
    # identity, so a worker can name its own bd issue without being told twice.
    # An EMPTY task exports NOTHING rather than `PI_WORKER_TASK=`: a reader
    # cannot tell a blank value from a stage whose ticket id happens to be
    # blank, and absence is what the rest of this protocol already means by
    # "nobody set this".
    let task_env = (if ($task | is-empty) { [] } else { ["-e" $"PI_WORKER_TASK=($task)"] })

    let worker_env = ([
        "-e" $"PI_WORKER_RUN=($run)"
        "-e" $"PI_WORKER_UID=($uid)"
        "-e" $"PI_WORKER_ROLE=($role)"
        "-e" $"PI_WORKER_BRANCH=($tree.branch)"
        "-e" $"PI_WORKER_SESSION=($session)"
        "-e" $"PI_WORKER_SKILL=($skill)"
        "-e" $"PI_WORKER_ISOLATION=($isolation)"
        "-e" $"PI_WORKER_WINDOW=($window)"
    ] ++ $task_env ++ $commit_guard)
    # Creating the session, not resuming one: this uid is new and its uuid was
    # minted moments ago.
    let window_id = (
        open-worker-window --target $target --name $window --cwd $tree.path
            --session $session --window-env $worker_env --socket $socket
    )

    # Re-record the identity now that the id exists. Written twice rather than
    # deferred: the first write is what leaves a resume handle behind when the
    # window never gets created at all.
    bus-identity $uid --run $run --identity {
        role: $role
        cwd: $tree.path
        branch: $tree.branch
        session: $session
        skill: $skill
        isolation: $isolation
        window: $window
        window_id: $window_id
        task: $task
        commissioner: $commissioner
    }

    {
        run: $run
        uid: $uid
        role: $role
        # What the address became. A caller that passed prose gets to see the
        # name it actually got rather than diffing it out of the window.
        subject: $subject
        window: $window
        window_id: $window_id
        cwd: $tree.path
        branch: $tree.branch
        session: $session
        skill: $skill
        isolation: $isolation
        # Named back so a dispatcher reads the association off its own spawn
        # result rather than having to remember what it passed.
        task: $task
        commissioner: $commissioner
        resume: $"pi --session ($session)"
        # Both, because they answer different questions. `live` is the bool an
        # operator skims; `liveness` is the verdict adr0017 requires when the
        # answer might be "I cannot tell" — see worker-liveness. Note this is a
        # snapshot taken moments after new-window, so a process that dies during
        # startup may still read `live` here; a later probe is what tells the
        # truth, which is why nothing downstream trusts this field.
        live: (worker-live? $window_id --socket $socket)
        liveness: (worker-liveness $window_id --socket $socket | get verdict)
    }
}

# ==================================================== stage completion gates
#
# A stage may report `complete` only when it carries the verdict its own
# discipline produces. The verdict is read from the typed `validation` field
# and NEVER from the summary: an assistant writing its verdict in prose is the
# exact forgery this design exists to refuse, and text is the one thing a
# model can always produce.
#
# spec-refinement is called out by name because its verdict is a specific
# token its own skill defines. Every other stage needs a non-empty verdict —
# whatever evidence that stage actually produces — because "complete with no
# verdict" is how an unvalidated result reaches the pipeline.



# ================================================== orchestration verbs (T5)
#
# The scrum-master's Pi branch drives the pipeline through these and nothing
# else. Each one is a state transition validated against the T1 table before
# anything is touched, so an illegal move is refused rather than half-applied.
#
# Two markers carry the states no result envelope can express, because they are
# granted from outside the worker: `accepted` (a reviewer or a successful merge
# said the work is done with) and `stopped` (someone tore it down). They live
# beside the placement record now (sp029 T6), not the worker's envelopes, so
# they survive exactly as long as the identity that makes them addressable —
# past a runtime wipe, and past the worktree they describe being reclaimed.
#
# `waiting_human` and `reopened` are NOT part of that move. `waiting_human`
# now has no writer at all: it used to be written from `worker-resume` on a
# second rejection, escalating the worker to `waiting_human` on ITS behalf,
# and that escalation policy is exactly what sp029 T8 retired — `resume` is
# now an ordinary send, with no rejection counting and no `escalate`.
# `reopened` keeps its writer, and deliberately: it is not escalation policy,
# it is what keeps a resumed worker's stale `complete` report from being
# re-served by `legacy-bus-wait`/`legacy-bus-pending` (still what `main
# wait`/`main status` call) as if it were fresh (dotfiles-nig0/ycvl). See the
# comment on `worker-resume`.
def marker-path [run: string, uid: string, name: string]: nothing -> string {
    if $name in ["accepted" "stopped"] {
        let slug = (resolve-agent-slug $run $uid)
        if $slug == null {
            error make {msg: $"cannot address the ($name) marker for ($run)/($uid): no identity recorded, so there is no durable placement to mark against \(adr0017)"}
        }
        agent-state-dir $slug $run $uid | path join $"($name).marker"
    } else {
        worker-dir $run $uid | path join $"($name).marker"
    }
}

def write-marker [run: string, uid: string, name: string, value: string = ""] {
    let marker = (marker-path $run $uid $name)
    let scratch = ($marker + $".tmp.(random chars --length 10)")
    (if ($value | is-empty) { now-stamp } else { $value }) | save -f $scratch
    chmod 600 $scratch
    mv -f $scratch $marker
}

def marker-value [run: string, uid: string, name: string]: nothing -> string {
    let marker = (marker-path $run $uid $name)
    if not ($marker | path exists) { return "" }
    open --raw $marker | str trim
}

def marker-set? [run: string, uid: string, name: string]: nothing -> bool {
    marker-path $run $uid $name | path exists
}

# Everything known about one worker, without consuming anything.
#
# sp029 T8: no rejection count. Counting how many times a worker was sent back
# was in service of the escalate-after-two-rejections rule, which retired with
# `worker-resume`'s writer — that policy now belongs to the consumer's own
# instructions ([[ft013]]), not to this inspection.
export def worker-inspect [uid: string, --run: string, --sessions-dir: string = ""]: nothing -> record {
    let identity = (bus-identity-of $uid --run $run)
    if $identity == null {
        error make {msg: $"unknown worker ($run)/($uid): no identity on the bus. Absent evidence is not permission to act \(adr0017)"}
    }
    let results = (read-box (worker-dir $run $uid | path join "outbox"))
    {
        run: $run
        uid: $uid
        identity: $identity
        state: (bus-status $uid --run $run | get state)
        last_result: (if ($results | is-empty) { null } else { $results | last | get payload })
        resume: (resume-hint $identity --sessions-dir $sessions_dir)
        transcript: (pi-session-file $identity.session --sessions-dir $sessions_dir)
    }
}

# Where Pi stores a session's transcript, or null when it cannot be found.
#
# Pi files sessions under one directory per project slug, named
# `<timestamp>_<uuid>.jsonl`. The timestamp is Pi's to choose, so the path
# cannot be predicted at spawn — it is located by id when someone asks.
#
# Returns null rather than a constructed path: sending an operator to a file
# that is not there is worse than telling them it is missing.
export def pi-session-file [session: string, --sessions-dir: string = ""]: nothing -> any {
    let base = (if ($sessions_dir | is-empty) {
        $env.HOME? | default "" | path join ".pi" "agent" "sessions"
    } else { $sessions_dir })
    if not ($base | path exists) { return null }

    let hits = (
        do { ^find $base -type f -name $"*_($session).jsonl" } | complete
        | if $in.exit_code == 0 { $in.stdout | lines } else { [] }
        | where {|l| ($l | str trim | is-not-empty) }
        | sort
    )
    if ($hits | is-empty) { null } else { $hits | first | str trim }
}

# What a worker is doing right now, as one short phrase.
#
# The bus only learns anything when a worker REPORTS, so `state` sits at
# `created` for almost the whole of a worker's life — accurate, and useless as
# an answer to "is it getting anywhere". The operator watching a row that says
# `warming-up` for two minutes has no way to tell work from a wedge.
#
# The worker's activity IS observable without changing the protocol: Pi writes
# its session as JSONL, and the identity already records which session. So this
# reads the last tool call out of the worker's own transcript.
#
# The worker's OWN evidence about ITSELF, which is the kind adr0017 trusts —
# and read-only observation, not coordination: nothing is written, and no
# decision is taken on it. If it cannot be read or parsed, the answer is
# nothing, and the row is exactly as informative as it was before.
#
# Only the tail is read. A long session's transcript grows without bound and
# this runs once per worker per poll; the last call is always at the end.
export def worker-activity [uid: string, --run: string, --sessions-dir: string = ""]: nothing -> string {
    let identity = (bus-identity-of $uid --run $run)
    if $identity == null { return "" }
    let file = (pi-session-file ($identity | get -o session | default "") --sessions-dir $sessions_dir)
    if $file == null { return "" }

    let tail = (do { ^tail -c 65536 $file } | complete)
    if $tail.exit_code != 0 { return "" }

    let calls = (
        $tail.stdout
        | lines
        | where {|l| ($l | str trim | str starts-with "{") }
        | each {|l| try { $l | from json } catch { null } }
        | where {|d| $d != null }
        | each {|d|
            # `describe` is NOT the test here. nu reports a homogeneous list of
            # records as `table<...>`, not `list<...>`, so a check for "list"
            # rejected every entry and this returned nothing at all. What
            # matters is whether it can be filtered, so try it.
            let content = ($d | get -o message.content | default [])
            try {
                $content | where {|c| ($c | get -o type | default "") == "toolCall" }
            } catch { [] }
        }
        | flatten
    )
    if ($calls | is-empty) { return "" }

    # The reporting call itself is dropped. It IS the last thing the worker
    # did, and it is already the loudest thing on the row: the state column
    # says `complete`, and the result's summary is one `inspect` away. Showing
    # `pi_worker_result` beside `complete` is the same column-restates-the-state
    # noise that the age and liveness columns were trimmed for.
    let substantive = ($calls | where {|c| ($c | get -o name | default "") != "pi_worker_result" })
    if ($substantive | is-empty) { return "" }
    let last = ($substantive | last)
    let name = ($last | get -o name | default "")
    let args = ($last | get -o arguments | default {})
    # The argument that says WHAT, per tool. A bare tool name answers half the
    # question: `bash` and `bash: git status --short` are not the same news.
    let hint = (
        ["command" "path" "file_path" "pattern" "query" "url"]
        | each {|k| $args | get -o $k | default "" }
        | where {|v| ($v | describe) == "string" and ($v | is-not-empty) }
        | get 0?
        | default ""
    )
    let short = (if ($hint | is-empty) { "" } else {
        let one = ($hint | str replace --all "\n" " " | str trim)
        if ($one | str length) > 44 { $"($one | str substring 0..43)…" } else { $one }
    })
    if ($short | is-empty) { $name } else { $"($name): ($short)" }
}

# How to get back into a worker's conversation, answered for the world as it is
# right now.
#
# dotfiles-lr2w: every result envelope carries `pi --session <id>`, and the T7
# checklist promised that command still works after `accept`. It does not. Pi
# binds a session to the directory it was created in and refuses to start once
# that directory is gone:
#
#   Stored session working directory does not exist: .../wk-t1.0
#
# Naming the session file instead of the id does not help — same refusal. The
# transcript survives, so nothing is lost, but the documented command cannot
# reach it. `pi --fork <file>` can, from any valid directory, which is the
# honest answer once a work stage's worktree has been reclaimed.
#
# Derived, never stored: the truth changes when the worktree is removed, and a
# recorded string would go stale at exactly that moment.
export def resume-hint [identity: record, --sessions-dir: string = ""]: nothing -> string {
    if ($identity.cwd | path exists) {
        return $"pi --session ($identity.session)"
    }
    let transcript = (pi-session-file $identity.session --sessions-dir $sessions_dir)
    if $transcript == null {
        return $"cannot resume: the worker's directory ($identity.cwd) no longer exists and no transcript for session ($identity.session) was found"
    }
    $"pi --fork ($transcript)"
}

# Every worker in a run, reconstructed from the bus alone.
#
# This is what makes an initiator restartable: no part of a run's shape lives
# in the orchestrator's memory, so a fresh process can list the workers, their
# states, their undelivered results and their resume commands.
export def run-workers [run: string, --repo: string = ""]: nothing -> list<record> {
    let dir = (bus-root | path join $run)
    if not ($dir | path exists) { return [] }
    let base = (if ($repo | is-empty) { current-repo } else { $repo })
    let slug = (resolve-project-slug $base)
    ls $dir | where type == dir | get name | sort | each {|w|
        let uid = ($w | path basename)
        let status = (bus-status $uid --run $run)
        let identity = (bus-identity-of $uid --run $run)
        {
            run: $run
            uid: $uid
            state: $status.state
            unacked: $status.unacked
            # dotfiles-v13r: which ticket this worker serves, so an
            # orchestrator rebuilding from the bus alone can route review,
            # merge and close back to the right bd issue. `get -o ... |
            # default ""` and not `$identity.task`: an identity written before
            # the field existed has no such column, and a roster that raises
            # on one is a roster nobody can use during exactly the recovery it
            # is for.
            task: (if $identity == null { "" } else { $identity | get -o task | default "" })
            window: (if $identity == null { "" } else { $identity.window })
            resume: (if $identity == null { "" } else { $"pi --session ($identity.session)" })
            # sp030 T3: the worker's own reported state, `unknown` past its
            # freshness bound (or unparseable), empty when it never published.
            presence: (presence-column $slug $uid)
        }
    }
}

# Every worker the bus knows about, across every run.
#
# The question an operator actually asks is "what is running and where do I
# find it?", and answering it used to require knowing the run id first. This
# carries only what locating a worker needs — who it is, whether it is alive,
# the window to look at, the command to open its transcript — and leaves the
# envelopes, counts and history to `inspect`.
#
# `liveness` needs tmux; when tmux cannot be reached it reports `unknown`
# rather than guessing, so a roster is still useful without a display host.
export def worker-roster [--run: string = "", --socket: string = ""]: nothing -> list<record> {
    let root = (bus-root)
    if not ($root | path exists) { return [] }

    let runs = (if ($run | is-empty) {
        ls $root | where type == dir | get name | sort | each {|d| $d | path basename }
    } else { [$run] })

    $runs | each {|r|
        let dir = ($root | path join $r)
        if not ($dir | path exists) { [] } else {
            ls $dir | where type == dir | get name | sort | each {|w|
                let uid = ($w | path basename)
                let envelope = (bus-identity-envelope $uid --run $r)
                let identity = (if $envelope == null { null } else { $envelope.payload })
                let window = (if $identity == null { "" } else { $identity.window })
                let target = (if $identity == null { "" } else { window-target $identity })
                let state = (bus-status $uid --run $r | get state)
                {
                    run: $r
                    uid: $uid
                    role: (if $identity == null { "" } else { $identity.role })
                    # dotfiles-v13r. Empty for an identity written before the
                    # ticket was recorded — the same absent-field treatment
                    # `window_id` below already gets, and for the same reason:
                    # a record from the previous build must still list.
                    task: (if $identity == null { "" } else { $identity | get -o task | default "" })
                    state: $state
                    liveness: (if ($target | is-empty) { "unknown" } else { worker-liveness $target --socket $socket | get verdict })
                    window: $window
                    # The frame wears this as a suffix on the address —
                    # `r32/impl-1@7` — so a row carries ONE name for a worker
                    # rather than the address and the window name side by side.
                    # Empty for an identity written before the id was recorded;
                    # the row then reads as the bare address.
                    window_id: (if $identity == null { "" } else { $identity | get -o window_id | default "" })
                    # When the worker was spawned. Empty rather than a
                    # substitute when no identity was ever written: a made-up
                    # start time would read as an idle worker.
                    started: (if $envelope == null { "" } else { $envelope.created })
                    # What it is doing, for workers that have not reported yet.
                    #
                    # Computed only for those, and deliberately: resolving a
                    # session file runs `find` over ~/.pi/agent/sessions, and
                    # this whole roster is rebuilt every five seconds by the
                    # frame. A worker that has already reported has a state and
                    # a summary saying more than its last tool call, so paying
                    # for one would buy nothing.
                    doing: (if $state in ["created" "running"] { worker-activity $uid --run $r } else { "" })
                    resume: (if $identity == null { "" } else { resume-hint $identity })
                }
            }
        }
    } | flatten
}

# Refuse commits from a worker that shares the operator's working tree.
#
# A stage with `isolation: main` puts the worker in the repo the operator is
# using, on whatever branch they are on. Six commits reached this repo's `main`
# that way in one evening, five files of them still tracked and pushed, because
# nothing stopped a worker doing the most ordinary thing a coding agent does.
#
# Guidance alone will not hold. `promptGuidelines` tells the worker not to, and
# a worker that decides committing is the helpful thing will commit anyway —
# the same reason `complete` is gated at the bus rather than requested in
# prose. So this is a git hook, and git enforces it.
#
# Delivered as `core.hooksPath` through GIT_CONFIG_* environment variables,
# which git honours per-process: nothing is written to the repo's config, the
# operator's own hooks are untouched, and the setting dies with the window.
#
# GENERATED into the worker's runtime directory rather than shipped as a file
# in this package, because the CLI is reached through a symlink in ~/.local/bin
# and a script cannot reliably find its own package directory from there — the
# same resolution problem install.sh works around for `use`.
#
# A worktree-isolated worker gets NO hook: it owns a throwaway branch and MUST
# commit, and bus-result refuses its `complete` if it has not.
export def write-commit-guard [run: string, uid: string, skill: string, branch: string]: nothing -> string {
    let dir = (worker-dir $run $uid | path join "githooks")
    ensure-dir $dir
    let refusal = ([
        "#!/usr/bin/env bash"
        "# Generated by pi-worker for a stage with isolation: main."
        "cat >&2 <<'MSG'"
        $"refusing to commit: this worker runs in the operator's own working tree."
        $""
        $"  stage:  ($skill)  \(isolation: main)"
        $"  branch: ($branch)"
        $""
        "A commit here lands on the operator's branch, not on a branch of your"
        "own. If this work needs committing, it needs a stage declared with"
        "isolation: worktree. If it does not, report your outcome without"
        "committing — or report blocked and say what you needed."
        "MSG"
        "exit 1"
    ] | str join "\n")
    for hook in ["pre-commit" "pre-push"] {
        let path = ($dir | path join $hook)
        $refusal | save -f $path
        chmod 700 $path
    }
    $dir
}

# Everything that happened to one worker, in order.
#
# Reconstructed, not recorded: every envelope already carries a `created`
# stamp and every marker's CONTENT is a stamp, so the history is on the bus
# already and this only reads it. Nothing new is written, which matters — a
# timeline that needed its own log would be a second source of truth about
# what happened, and would disagree with the envelopes the moment one was
# written and the other was not.
#
# The deltas are the point. A worker's wall-clock life is easy to see in the
# frame; where the time WENT is not, and the answer is usually one gap —
# thirty seconds between `sent` and `reported` is the agent thinking, thirty
# seconds between `reported` and `acked` is the orchestrator not listening.
export def worker-timeline [uid: string, --run: string]: nothing -> list<record> {
    let dir = (worker-dir $run $uid)
    if not ($dir | path exists) { return [] }

    # Identity itself lives off the runtime tree now (sp029 T6); the log of
    # every re-record is read from its durable location via the same
    # `(run, uid)` index `bus-identity-envelope` uses.
    let idir = (identity-log-dir $run $uid)
    let identity = (
        (if $idir == null { [] } else { read-box $idir })
        | enumerate
        | each {|e|
            {
                at: $e.item.created
                class: "identity"
                envelope: null
                value: ""
                event: (if $e.index == 0 { "spawned" } else { "identity" })
                detail: (
                    if $e.index == 0 {
                        $"($e.item.payload.window) · branch ($e.item.payload.branch) · ($e.item.payload.cwd)"
                    } else {
                        # The re-record exists to add the window id tmux chose.
                        $"window_id ($e.item.payload | get -o window_id | default '?')"
                    }
                )
            }
        }
    )

    let inbox = (
        read-box ($dir | path join "inbox")
        | each {|e|
            let payload = $e.payload
            let what = (if ("task" in ($payload | columns)) {
                $"ticket ($payload.task)"
            } else {
                $"($payload | get -o instructions | default '' | str length) chars of instructions"
            })
            {at: $e.created, class: "inbox", envelope: null, value: "", event: $"sent seq ($e.sequence)", detail: $"stage ($payload.stage) · ($what)"}
        }
    )

    let outbox = (
        read-box ($dir | path join "outbox")
        | each {|e|
            let payload = $e.payload
            let verdict = (if $e.kind == "error" {
                $"($payload | get -o code | default 'error'): ($payload | get -o detail | default '')"
            } else {
                $"($payload | get -o status | default '?') — ($payload | get -o summary | default '')"
            })
            {at: $e.created, class: "result", envelope: $e, value: "", event: $"reported seq ($e.sequence)", detail: $verdict}
        }
    )

    # An ack is a file whose name is the sequence and whose body is the stamp.
    let acks = (
        glob ($dir | path join "outbox" "*.ack")
        | each {|f|
            {
                at: (open --raw $f | str trim)
                class: "ack"
                envelope: null
                value: ""
                event: $"acked seq ($f | path basename | str replace '.ack' '')"
                detail: "receipt, not acceptance"
            }
        }
    )

    let markers = (
        glob ($dir | path join "*.marker")
        | each {|f|
            let name = ($f | path basename | str replace ".marker" "")
            let body = (open --raw $f | str trim)
            # `reopened` stores the sequence it covers rather than a stamp, so
            # it has no time of its own to sort by; the file's mtime is the
            # honest answer for it.
            let stamped = (if ($body =~ '^\d{4}-\d{2}-\d{2}T') { $body } else { ls $f | get 0.modified | format date "%Y-%m-%dT%H:%M:%S%.6fZ" })
            {at: $stamped, class: "marker", envelope: null, value: $body, event: $name, detail: (if $body == $stamped { "" } else { $"covers seq ($body)" })}
        }
    )

    let events = ([$identity $inbox $outbox $acks $markers] | flatten | sort-by at)
    if ($events | is-empty) { return [] }

    let first = ($events | first | get at | into datetime)

    # The state column is REPLAYED, not recorded: the evidence up to each event
    # is handed to the same derive-state the frame asks. So the timeline cannot
    # disagree with the row above it — and where it changes state is where the
    # frame changed too, which is the whole point of putting them side by side.
    #
    # A `reopened` marker is the one event whose position in time is a guess
    # (its body holds a sequence, not a stamp, so the file's mtime stands in),
    # and it is also the one that can move state backwards to `running`. Worth
    # knowing when reading a rejected worker's history.
    $events
    | reduce --fold {results: [], markers: {}, out: []} {|e, acc|
        let results = (if $e.class == "result" { $acc.results | append $e.envelope } else { $acc.results })
        let markers = (if $e.class == "marker" {
            if $e.event == "reopened" {
                $acc.markers | upsert reopened $e.value
            } else {
                $acc.markers | upsert $e.event true
            }
        } else { $acc.markers })
        {
            results: $results
            markers: $markers
            out: ($acc.out | append {
                at: $e.at
                "+s": (((($e.at | into datetime) - $first) / 1sec | math round --precision 1))
                event: $e.event
                state: (derive-state $results $markers)
                detail: $e.detail
            })
        }
    }
    | get out
}

# Let go of a finished worker's address.
#
# The occupied-address guard claims an address for the life of the worker, so
# repeating a run otherwise needs a fresh id every time. This is the
# deliberate way to reuse one.
#
# Project-wide since dotfiles-bg65, because that is the scope a uid is an
# address in: the runtime worker directory goes, and so do the PROJECT-level
# records that make the uid resolvable — the durable placement record
# (`agents/<run>/<uid>`, what `resolve-run` answers from), its slug pointer,
# the address claim, and the bus queue. Leaving any of them would leave the
# address taken while the tool tells its callers that `rm` is how an address
# is recycled, and a later `mint-uid` would have to skip it forever.
#
# The placement record can go here and nowhere else: `worktrees-reclaim` keeps
# a tree only while its claim is in a WORKING state, so a stopped or accepted
# worker's tree was already sweepable before this record was removed — which
# is why deleting it on an explicit `rm` changes no sweep's verdict.
#
# Refused while the worker is unfinished: its envelopes may be the only record
# of what it did, and `running`, `blocked` or `waiting_human` all mean something
# may still be waiting on it. Only a terminal worker is discardable.
export def worker-release [--run: string, --uid: string]: nothing -> record {
    let dir = (worker-dir $run $uid)
    # Which project this address belongs to comes from the durable `.index`
    # pointer, and NEVER from the identity's own `cwd`. `accept` deletes that
    # worktree (`worktree-cleanup --path $identity.cwd --accepted`), so by the
    # time the normal `accept` then `rm` sequence reaches here the path is
    # gone; `resolve-project-slug` catches `main-worktree`'s failure and slugs
    # the dead path verbatim, which lands in its documented fallback bucket —
    # a slug holding none of this worker's records. Releasing there frees
    # nothing, and the address plus its queue stay reserved forever, which is
    # the exact failure the widened scope above exists to prevent. `.index`
    # exists for precisely this lookup: `(run, uid)` is all a caller has.
    let slug = (resolve-agent-slug $run $uid)
    let placement = (if $slug == null { "" } else { agent-state-dir $slug $run $uid })
    let claim = (if $slug == null { "" } else { address-dir $slug | path join $uid })

    # Known by ANY of its records, not by the runtime tree alone. That tree is
    # wiped at logout by design (sp029 T6), and a worker whose durable record
    # outlived the wipe is exactly the one whose address most needs releasing —
    # returning "no such worker" there made the documented recycle path a
    # silent no-op after every logout.
    let known = (
        ($dir | path exists)
        or (($placement | is-not-empty) and ($placement | path exists))
        or (($claim | is-not-empty) and ($claim | path exists))
    )
    if not $known {
        return {run: $run, uid: $uid, removed: false, reason: "no such worker"}
    }
    let state = (bus-status $uid --run $run | get state)
    if $state not-in ["stopped" "accepted"] {
        error make {msg: $"refusing to release ($run)/($uid): it is ($state), and its envelopes may be the only record of what it did. Stop or accept it first"}
    }

    if ($dir | path exists) { rm -rf $dir }
    # A run directory with nothing left in it is just clutter.
    let run_dir = (run-dir $run)
    if ($run_dir | path exists) and ((ls $run_dir | length) == 0) { rm -rf $run_dir }

    if $slug != null {
        release-address-at $slug $uid
        let queues = (queue-dir-of $slug)
        if ($queues | is-not-empty) {
            let queue = ($queues | path join $uid)
            if ($queue | path exists) { rm -rf $queue }
        }
        if ($placement | path exists) { rm -rf $placement }
        # The run level is per-run bookkeeping, not a record of its own.
        let runs = (state-root | path join $slug "agents" $run)
        if ($runs | path exists) and ((ls $runs | length) == 0) { rm -rf $runs }
    }
    let pointer = (agent-index-path $run $uid)
    if ($pointer | path exists) { rm -rf $pointer }

    {run: $run, uid: $uid, removed: true, state: $state}
}

# Send a worker back with reviewer feedback, resuming its ORIGINAL session.
#
# Resuming rather than dispatching fresh is the point of a stable session id:
# the worker still has its context and its worktree, so the second attempt
# starts from the first rather than from nothing.
#
# sp029 T8: the message itself is now ordinary. There is no rejection count
# scanned off the inbox, no `escalate` on a second rejection, and no
# auto-parking at `waiting_human` — that policy (how many times is too many,
# and what happens then) was review policy, never transport, and it moves to
# the consumer's own instructions ([[ft013]]). Rejection-counting could not
# survive this anyway: it scanned for a `stage: "rejection"` marker on the
# sent message, and the message sent below carries no `stage` at all.
#
# The `reopened` MARKER survives, and deliberately does not follow the
# vocabulary it used to ride with. It is not escalation policy — it is the
# thing that keeps a resumed worker's stale `complete` report from being
# re-served as if it were fresh (dotfiles-nig0/ycvl). `main status` still
# reads it via `bus-status`'s `derive-state`/`unacked` precedence, which is
# unchanged by T9 — that read path is `bus-status`'s own, not the CLI's, and
# migrating it needs the same "what does unacked mean once a result is a
# queued message" design the comment on `legacy-ack-path` defers. `main wait`
# itself no longer touches this marker at all post-T9 (it reads the
# commissioner's queue, addressed by `--as`, with no notion of "the run's
# pending results" to skip past) — but `legacy-bus-wait`/`legacy-bus-pending`
# still read it, for the regression tests that exercise them directly.
# Dropping the write now would reopen a previously-fixed bug with its
# guarding tests still in the suite, for a vocabulary reason that does not
# apply to it.
export def worker-resume [
    uid: string
    --run: string
    --feedback: string
    --socket: string = ""
]: nothing -> record {
    let seen = (worker-inspect $uid --run $run)

    # Feedback goes to a PROCESS. A worker whose window is gone — accepted,
    # stopped, swept, or crashed — has nothing reading its inbox, and the
    # message used to land there anyway: the state flipped to `running`, the
    # verb reported success, and nobody was working. Refused rather than
    # silently queued, and the refusal names the verb that can bring the worker
    # back on the same session.
    #
    # `unknown` is not a refusal. adr0017: absence of evidence about tmux is
    # not evidence the worker is gone, and refusing on it would break resume
    # whenever the display host cannot be reached.
    let alive = (worker-liveness (window-target $seen.identity) --socket $socket)
    if $alive.verdict not-in ["live" "unknown"] {
        error make {msg: $"cannot resume ($run)/($uid): its window ($seen.identity.window) is ($alive.verdict), so nothing would read the feedback. Bring it back on its own session first: `respawn ($uid) --run ($run) --repo <repo>`"}
    }

    legacy-inbox-send $uid --run $run --payload {
        instructions: $feedback
        artifacts: []
    }

    # `complete -> running` is a legal edge precisely so a rejected result can
    # be sent back without inventing a new worker — validated here so a resume
    # sent to a worker in a terminal state (accepted, stopped) is refused
    # rather than silently accepted.
    validate-transition $seen.state "running"
    rm -f (marker-path $run $uid "waiting_human")
    let newest = (
        read-box (worker-dir $run $uid | path join "outbox")
        | each {|e| $e.sequence }
        | append 0
        | math max
    )
    write-marker $run $uid "reopened" ($newest | into string)

    {
        run: $run
        uid: $uid
        session: $seen.identity.session
        window: $seen.identity.window
        state: (bus-status $uid --run $run | get state)
    }
}

# Accept a completed worker: close its window and clean its worktree.
#
# The gates are deliberately stacked. Only a `complete` worker may be accepted
# (the T1 table's single edge into `accepted`), the worktree must hold no
# uncommitted work, and both the window and the worktree are addressed through
# this run's own identity record — so an acceptance can only ever reach the
# worker it names, never another run's.
export def worker-accept [
    uid: string
    --run: string
    --repo: string
    --socket: string = ""
]: nothing -> record {
    let seen = (worker-inspect $uid --run $run)
    # Idempotent for the same reason stop is: a retried acceptance has nothing
    # left to do, and the worktree it would have reclaimed is already gone.
    if $seen.state == "accepted" {
        return {run: $run, uid: $uid, state: "accepted", changed: false, reason: "already accepted"}
    }
    validate-transition $seen.state "accepted"

    # An isolation=main stage runs IN the main worktree, shared with the operator
    # and is nobody's to delete. There is no isolated directory or task branch
    # to reclaim, so acceptance is the marker alone.
    let isolated = ($seen.identity.cwd != (main-worktree $repo))

    # Every refusal is collected BEFORE the window dies (dotfiles-pwxf). The
    # comment below is true — a window is recoverable from the session id and a
    # worktree is not — but it only holds once the cleanup is known to be
    # possible: an acceptance that closed the window and then declined to
    # finish left the operator without the one place the work was visible, for
    # nothing.
    if $isolated {
        (worktree-cleanup-guard --repo $repo --path $seen.identity.cwd
            --branch $seen.identity.branch --accepted)
    }

    # The window closes first: it is recoverable (spawn again from the session
    # id), whereas the worktree is not, so the irreversible step goes last.
    do { ^tmux ...(tmux-args $socket) kill-window -t (window-target $seen.identity) } | complete | ignore

    if $isolated {
        worktree-cleanup --repo $repo --path $seen.identity.cwd --branch $seen.identity.branch --accepted
    }
    write-marker $run $uid "accepted"
    {run: $run, uid: $uid, state: "accepted", changed: true}
}

# Bring a reclaimed worker back, on the same Pi session, under a new address.
#
# `accept` reclaims a verified worker's window, worktree and branch and keeps
# its identity envelope, so the session id — the whole of what a restore needs
# — outlives the resources. This is the way back, and it is what makes that
# teardown safe to do the moment the work is judged correct.
#
# A NEW uid rather than a revival of the old one. `accepted` has no outgoing
# edge in the transition table on purpose: it records that the work was taken
# and closed, and a state a worker can leave records nothing. So the history
# stays literally true — the old worker was accepted, and a new one continues
# its transcript — with the lineage written on the new identity as
# `respawned_from` so the graph can be walked either way.
#
# The tree is reconstructed, not resurrected: on the recorded branch when that
# ref still exists (a stopped worker keeps its branch, and it may hold the only
# copy of its commits), and off base when it was deleted as merged, because
# then the work is in the base and a fresh iteration is the honest answer. The
# report says which happened rather than leaving the caller to diff it.
export def worker-respawn [
    uid: string
    --run: string
    --repo: string
    --socket: string = ""
]: nothing -> record {
    let old = (bus-identity-of $uid --run $run)
    if $old == null {
        error make {msg: $"cannot respawn ($run)/($uid): no identity on the bus for it, so there is no session to continue. Absent evidence is not permission to invent one \(adr0017)"}
    }

    # A live worker is not respawned: two Pi processes on one session id means
    # two writers on one transcript, and the window it already has is the
    # answer to whatever prompted the call.
    let seen = (worker-liveness (window-target $old) --socket $socket)
    if $seen.verdict == "live" {
        error make {msg: $"($run)/($uid) is still live in window ($old.window); respawn continues a worker whose process is gone. Look at the window it has, or stop it first"}
    }

    let repo = (expand-path $repo)
    # `<role>-<subject>@<project>` is the naming worker-window-name applies, so
    # it is also where the subject and project can be read back from. Parsed
    # off the END for the project: a subject may contain `-`, and a ticket-shaped
    # one contains `.`, but `@` separates exactly once by construction.
    let parts = ($old.window | split row "@")
    let project = ($parts | last)
    let subject = (
        $parts
        | drop 1
        | str join "@"
        | str replace $"($old.role)-" ""
    )
    # Resolved before anything is allocated, exactly as spawn does: a wrong or
    # gone session group must not leave a worktree behind to prune by hand.
    let target = (resolve-project-session $project --socket $socket)

    # Project-scoped, like every other mint: a respawn's new uid is an
    # address on the same bus its predecessor was on (dotfiles-bg65).
    let new_uid = (mint-uid $old.role $repo)
    let main = (main-worktree $repo)
    # The branch is what a respawn wants to land on, and its directory too when
    # one is still registered: a released-but-unaccepted worker leaves both
    # behind, and allocating a fresh iteration beside the work would be the one
    # outcome nobody asked for. Its own directory is only re-created when the
    # ref survived without one (a swept tree).
    let registered = (registered-worktrees $repo | where branch == $old.branch)
    let reuse = ($old.branch in (known-branches $repo))
    let tree = (if (expand-path $old.cwd) == $main {
        # An isolation=main worker shares the operator's tree; there was never
        # a directory of its own to rebuild.
        {path: $main, branch: $old.branch, isolated: false}
    } else if $reuse and ($registered | is-not-empty) {
        # Still on disk and still registered: walk back into it.
        {path: (expand-path ($registered | first | get path)), branch: $old.branch, isolated: true}
    } else if $reuse {
        let path = (worktrees-dir $repo | path join $old.branch)
        let added = (do { ^git -C $repo worktree add --quiet $path $old.branch } | complete)
        if $added.exit_code != 0 {
            error make {msg: $"could not re-create a worktree for ($old.branch): ($added.stderr | str trim)"}
        }
        {path: $path, branch: $old.branch, isolated: true}
    } else {
        # This branch is reached only when the old branch is gone (merged or
        # deleted) and the old placement was not the main worktree — so a
        # fresh throwaway worktree is exactly what "worktree" means.
        worker-placement --repo $repo --isolation "worktree" --subject $subject
    })

    # `old.isolation` is recorded directly on a post-T8 identity; an identity
    # written before this change (or imported from v1) has none, so it is
    # derived from where the reconstructed tree actually landed instead of
    # guessed from a skill name.
    let isolation = ($old | get -o isolation | default (if $tree.isolated { "worktree" } else { "main" }))

    let window = (worker-window-name $old.role $subject $project)
    # sp029 T5: carries the prior identity's commissioner forward — a
    # respawn continues the same worker under a new uid, so it still owes
    # its result to whoever the original spawn commissioned it for.
    let commissioner = ($old | get -o commissioner | default $run)
    # dotfiles-v13r: and the ticket, for the same reason — a respawn continues
    # the same worker under a new address, so it still serves the same bd
    # issue. Without this the association would survive exactly one respawn.
    # Absent on an identity written before the field existed, which reads as
    # "no ticket" rather than raising.
    let task = ($old | get -o task | default "")
    bus-identity $new_uid --run $run --identity {
        role: $old.role
        cwd: $tree.path
        branch: $tree.branch
        session: $old.session
        skill: $old.skill
        isolation: $isolation
        window: $window
        task: $task
        respawned_from: $uid
        commissioner: $commissioner
    }

    let commit_guard = (if not $tree.isolated {
        let hooks = (write-commit-guard $run $new_uid $old.skill $tree.branch)
        [
            "-e" "GIT_CONFIG_COUNT=1"
            "-e" "GIT_CONFIG_KEY_0=core.hooksPath"
            "-e" $"GIT_CONFIG_VALUE_0=($hooks)"
        ]
    } else { [] })
    let task_env = (if ($task | is-empty) { [] } else { ["-e" $"PI_WORKER_TASK=($task)"] })
    let worker_env = ([
        "-e" $"PI_WORKER_RUN=($run)"
        "-e" $"PI_WORKER_UID=($new_uid)"
        "-e" $"PI_WORKER_ROLE=($old.role)"
        "-e" $"PI_WORKER_BRANCH=($tree.branch)"
        "-e" $"PI_WORKER_SESSION=($old.session)"
        "-e" $"PI_WORKER_SKILL=($old.skill)"
        "-e" $"PI_WORKER_ISOLATION=($isolation)"
        "-e" $"PI_WORKER_WINDOW=($window)"
    ] ++ $task_env ++ $commit_guard)

    # Resuming, not creating: the session exists and holds the transcript this
    # worker is being brought back for.
    let window_id = (
        open-worker-window --target $target --name $window --cwd $tree.path
            --session $old.session --window-env $worker_env --socket $socket --resume
    )
    bus-identity $new_uid --run $run --identity {
        role: $old.role
        cwd: $tree.path
        branch: $tree.branch
        session: $old.session
        skill: $old.skill
        isolation: $isolation
        window: $window
        window_id: $window_id
        task: $task
        respawned_from: $uid
        commissioner: $commissioner
    }

    {
        run: $run
        uid: $new_uid
        from: $uid
        role: $old.role
        session: $old.session
        window: $window
        window_id: $window_id
        cwd: $tree.path
        branch: $tree.branch
        # From the DECISION, not from comparing names: allocation hands out the
        # lowest free iteration, so a deleted `wk-t1.0` is handed out again and
        # a name comparison would call a fresh ref a reused one.
        reused_branch: $reuse
        task: $task
        commissioner: $commissioner
        resume: $"pi --session ($old.session)"
        live: (worker-live? $window_id --socket $socket)
        liveness: (worker-liveness $window_id --socket $socket | get verdict)
    }
}

# Tear a worker down without accepting its work.
#
# Stopping closes the window and nothing else. The worktree may hold unmerged
# commits, so it stays until something explicitly says the work is finished
# with — `stopped` is terminal, and a stopped worker can never become
# `accepted`.
# Tear a worker down without accepting its work.
#
# Idempotent. An initiator that retries — after a timeout, or because it lost
# track of what it had already torn down — must not be told it did something
# illegal for asking to stop something already stopped. The state is terminal,
# so the second call has nothing to do.
#
# That is not permission to re-enter a terminal state: an ACCEPTED worker still
# refuses to be stopped, because acceptance records that the work was taken and
# a later stop would rewrite what happened.
export def worker-stop [uid: string, --run: string, --socket: string = ""]: nothing -> record {
    let seen = (worker-inspect $uid --run $run)
    if $seen.state == "stopped" {
        return {run: $run, uid: $uid, state: "stopped", changed: false, reason: "already stopped"}
    }
    validate-transition $seen.state "stopped"
    do { ^tmux ...(tmux-args $socket) kill-window -t (window-target $seen.identity) } | complete | ignore
    write-marker $run $uid "stopped"
    {run: $run, uid: $uid, state: "stopped", changed: true}
}

# Every result a worker has reported, oldest first. Envelopes are append-only,
# so a later completion does not erase an earlier failure — the history stays
# auditable rather than being overwritten by the latest word.
export def read-results [uid: string, --run: string]: nothing -> list<record> {
    read-box (worker-dir $run $uid | path join "outbox") | each {|e| $e.payload }
}

# Record acceptance without touching tmux or git. worker-accept is the verb an
# orchestrator uses; this is the state half on its own, for callers that have
# already done the cleanup (and for tests that need the state without a repo).
export def mark-accepted [uid: string, --run: string] {
    let state = (bus-status $uid --run $run | get state)
    validate-transition $state "accepted"
    write-marker $run $uid "accepted"
}

# ============================================================== CLI entry point
#
# The installer links this file into ~/.local/bin/pi-worker, so it has to
# work as a command and not only as an imported module. Every verb below is a
# thin wrapper over the exported function of the same name: the CLI is a
# surface, never a second implementation that could drift from the one the
# tests drive.
#
# Output is JSON, because every consumer is another program — the scrum-master
# skill, a shell conditional, or a test.

# Refuse a missing flag BY NAME, saying what it is for.
#
# A flag declared `string` with no default arrives as null when omitted, and
# nushell reports the consequence four calls deeper:
#
#     Error: nu::shell::cant_convert
#       x Can't convert to string.
#
# which names no verb, no flag and no remedy. `main spawn` has guarded against
# that from the start; a sweep of the surface found fifteen of seventeen verbs
# did not, and one of them cost an operator a worker stuck at `complete` while
# its orchestrator retried a call that could never succeed (dotfiles-kuw5).
#
# A refusal has to say what is missing and what it is for, or it is just a
# slower way of saying no.
def require-flags [verb: string, wanted: table<flag: string, value: any, what: string>] {
    for w in $wanted {
        let given = (if $w.value == null { "" } else { $w.value | into string })
        if ($given | is-empty) {
            error make {msg: $"($verb) needs ($w.flag): ($w.what)"}
        }
    }
}

# What a verb calls the worker it acts on. sp029 T9: there is no more "run the
# worker belongs to" concept on the CLI — every verb below resolves its own
# worker's project scope from the repository the caller is standing in
# (`resolve-run`), so there is nothing left for a caller to type or drift
# across three copies of the wording.
const UID_IS = "the worker's id in this project, e.g. impl-1. `ps`/`workers` list them"

def usage []: nothing -> string {
    [
        "pi-worker — visible Pi worker orchestration (ft014)"
        ""
        "USAGE"
        "  pi-worker <verb> [flags]"
        ""
        "  Every verb operates on the CURRENT PROJECT: the repository the caller"
        "  is standing in, derived the same way spawn already derives --repo."
        "  There is no run id to mint, pass, or look up — a uid is looked up"
        "  wherever this project last recorded it."
        ""
        "VERBS"
        "  spawn    --uid --role --subject --project --repo --session --skill"
        "           --isolation worktree|main (no default) [--task]"
        "           [--commissioner <address>] [--socket]"
        "  send     --as --to --content         address a message to one or more agents"
        "  result   --as --status --summary [--validation]   report an outcome"
        "  settled  --as                         report settling with nothing to show"
        "  wait     --as [--block] [--timeout]  mail addressed to --as, or nothing"
        "  rm       --uid                        release a finished worker's address"
        "  status   <uid>                        one worker's state, from the bus"
        "  liveness <uid> [--socket]             live | exited | unknown, from tmux"
        "  inspect  <uid>                        identity, last result, resume command"
        "  ps       [--socket]                   every worker, where it is and whether it lives"
        "  workers                               every worker in this project, from the bus alone"
        "  resume   <uid> --feedback             send back to the ORIGINAL session"
        "  accept   <uid> --repo                 close the window, remove the worktree"
        "  respawn  <uid> --repo                 bring a reclaimed worker back: a NEW uid"
        "                                       on the SAME Pi session, tree rebuilt"
        "  stop     <uid>                        close the window, KEEP the worktree"
        "  reclaim  --repo [--base] [--socket] [--remote] [--force] [--dry-run]"
        "                                       sweep a PROJECT: every worker tree no"
        "                                       live worker owns, plus the dead worker"
        "                                       windows tmux still lists. Session ids survive."
        "                                       --remote <name> also sweeps pushed wk- refs"
        "                                       off that remote; without it nothing leaves"
        "                                       this machine"
        "  doctor                               check dependencies"
        ""
        "NOTES"
        "  spawn --task names the bd ticket the worker serves. It names the"
        "  worker's branch as it always did, AND is now recorded on the identity,"
        "  so `inspect`/`ps`/`workers` answer 'which ticket is this?' after a"
        "  crash; the window gets it as PI_WORKER_TASK."
        "  spawn --commissioner names WHO is told when the worker reports."
        "  Default: the run this spawn minted, which is why `wait --as <run>`"
        "  (reading `run` out of the spawn result) is the convention without it."
        "  An orchestrator holding its own address should pass it here and then"
        "  `wait --as <its own address>` — otherwise the completion is delivered"
        "  correctly to an address it is not listening on, silently."
        "  wait both reads AND marks: there is no separate ack step any more, so"
        "  --as may only name this session's own address (PI_WORKER_UID, when"
        "  set) — reading and marking someone else's queue crosses the one"
        "  ownership line the bus enforces. Observe another agent's mail with"
        "  `status`/`inspect` instead, which take any uid freely."
        "  The work stays in the worktree and the branch; `accept` reclaims"
        "  those, and `respawn` brings the worker back on its session id."
        "  stop keeps a tree because it may hold unmerged commits; reclaim is the"
        "  per-project sweep for when a round of work is done with. Nothing a"
        "  resume needs lives in a tree — the session id is on the bus."
        "  So accept as soon as the work is judged correct, and respawn if the"
        "  worker is wanted again: same transcript, new address, rebuilt tree."
    ] | str join "\n"
}

# The rest parameter exists so an unrecognised verb produces a useful message.
# Without it nushell reports "Extra positional argument", which names neither
# what was asked for nor what is available — the two things the operator needs.
def main [...args: string] {
    if ($args | is-empty) {
        print (usage)
        return
    }
    print --stderr $"pi-worker: unknown verb '($args | first)'"
    print --stderr ""
    print --stderr (usage)
    exit 2
}

# sp029 T9: `--run` retired from the CLI entirely. A run was always minted
# when omitted (`next-run-id`), so every spawn already had this shape; the
# only change is that there is no flag left pretending an explicit value was
# ever load-bearing here. `--uid` is still optional and minted when absent;
# the result names what was chosen, so a caller spawning siblings reads the
# uid back off its first spawn instead of inventing one.
def "main spawn" [
    --uid: string = "", --role: string = "", --subject: string
    --project: string = "", --repo: string = "", --session: string = "", --skill: string
    --isolation: string, --task: string = "", --commissioner: string = ""
    --socket: string = ""
] {
    # Derived before the check below, so the caller is only asked for what
    # cannot be worked out from where it is standing.
    let project = (if ($project | is-empty) { current-session-group } else { $project })
    let repo = (if ($repo | is-empty) { current-repo } else { $repo })

    # Required arguments, refused BY NAME.
    #
    # These were declared `string` with no default, so omitting one propagated
    # a null inward until some helper died on it:
    #
    #     Error: nu::shell::cant_convert
    #       x Can't convert to string.
    #
    # which names no verb, no argument, and no remedy. An agent driving this
    # tool burned turns on it. A refusal has to say what is missing and what it
    # is for, or it is just a slower way of saying no.
    for required in [
        [flag       value       what];
        ["--role"   $role       "the worker's role, e.g. impl or rev; it appears in the window name"]
        ["--subject" $subject   "a short name for the work; it becomes the window name and the branch, slugified if it is not already a slug"]
        ["--project" $project   "the tmux session group to host the window. Normally derived from the session you are in — pass it only when running outside tmux"]
        ["--repo"    $repo      "the git repository the worker works in. Normally derived from the current directory — pass it only when that is not a repository"]
        ["--skill"   $skill     "a label for what this worker does; travels as identity, not a lookup key"]
        ["--isolation" $isolation $"worktree or main, with no default — ($ISOLATIONS | str join ' or '): nothing may land in the main worktree without this being typed"]
    ] {
        if ($required.value | is-empty) {
            error make {msg: $"spawn needs ($required.flag): ($required.what)"}
        }
    }

    # Not just present — one of the two words. A typo here must not fall
    # through to the shared tree the way an unchecked isolation once could.
    if $isolation not-in $ISOLATIONS {
        error make {msg: $"spawn --isolation must be one of ($ISOLATIONS | str join ', '), got '($isolation)'"}
    }

    # --subject is no longer refused for being prose: worker-spawn slugifies it
    # (see slugify-subject, which also explains why that is now the policy) and
    # reports the name it produced. --task below is a different matter — it is
    # an ID, and an id that has been mangled to fit is not that id any more.

    # `--task` names the branch when it is given (see subject_for_branch in
    # worker-spawn), so it is under exactly the same constraint as --subject
    # and was under none of it. Observed: an agent put its whole instruction
    # prose here and got
    #
    #     could not allocate a worktree for Create a new text file in
    #     /home/jan/.dotfiles whose filename is the current timestamp ...
    #     after 64 attempts
    #
    # which is git refusing 64 candidate branch names and saying so at the
    # wrong altitude entirely. sp029 T8: whether a message is ticket-shaped or
    # prose is no longer a registry gate on --task itself — that belongs to
    # whoever sends the work (`send`) — but --task still names a branch, so it
    # still has to look like one.
    if ($task | is-not-empty) {
        if ($task | str length) > $MAX_SUBJECT_CHARS {
            error make {msg: $"spawn's --task is ($task | str length) characters; it names the worker's git branch, so it must be a ticket id, not a description. What the worker should DO belongs in the message"}
        }
        if ($task =~ '\s') {
            error make {msg: $"spawn's --task may not contain whitespace: it names the worker's git branch. Pass a ticket id like 'dotfiles-2mzv'; the instructions go in `send --instructions`"}
        }
    }

    let run = (next-run-id)
    let session = (if ($session | is-empty) { mint-session } else { $session })
    let minted = ($uid | is-empty)

    # Retried only when the address was MINTED. Two spawns racing can each mint
    # the same lowest-free uid for the project, and `claim-address`'s atomic
    # create is what notices — the loser is refused, re-mints, and takes the
    # next free address. An explicitly passed uid gets no retry: its refusal is
    # the answer the caller asked for, and quietly spawning somewhere else
    # would be worse than failing.
    mut attempt = 0
    loop {
        let uid = (if $minted { mint-uid $role $repo } else { $uid })
        let outcome = (try {
            {ok: true, value: (worker-spawn --run $run --uid $uid --role $role --subject $subject --project $project --repo $repo --task $task --session $session --skill $skill --isolation $isolation --commissioner $commissioner --socket $socket)}
        } catch {|e|
            {ok: false, error: $e}
        })
        if $outcome.ok {
            $outcome.value | to json | print
            return
        }
        $attempt = $attempt + 1
        if (not $minted) or $attempt >= 5 { error make $outcome.error.raw }
    }
}

# ------------------------------------------------------------ sp029 T9: CLI addressing
#
# `--run` is gone from every verb below. It used to be a caller-minted id
# threading `send`/`wait`/`ack`/`result`/`settled`/`status`/... through one flat
# per-run tree; the peer-addressed bus (T3/T4) already dropped it for
# `send`/`wait` — `resolve-run` below is what lets the orchestration verbs
# (`status`, `accept`, `resume`, ...) keep calling the still-run-shaped
# internal functions (`bus-identity-of`, `worker-inspect`, ...) without a
# caller ever typing one, by resolving a uid within the CALLER's own project
# — never a wider scan.
#
# Scoped to exactly one project slug, computed the same way `project-dir`
# computes one: `main-worktree` of `--repo` (or the caller's cwd when it is
# not given), so a `wk-*` worktree's caller resolves to the same slug as the
# main worktree it belongs to. This is deliberate, not merely convenient:
# sp029's `## solution` states "cross-project addressing stays structurally
# impossible — one directory per project", and a uid lookup that scanned
# every project this user's state-home holds — picking the first match when
# two happened to collide — would turn that structural guarantee into a coin
# flip. A caller genuinely outside any project (no derivable repo) gets
# `resolve-project-slug`'s own documented fallback bucket, keyed off its raw
# cwd, exactly like a hand-built test fixture recording an identity at a
# throwaway path — the two only ever agree when both actually stand in (or
# under) the same real project, which is what every genuine caller does.
#
# An unknown uid resolves to "" rather than refusing here: the downstream
# identity check (already run/uid-shaped) reports "unknown" on ANY run value
# that does not resolve, so a wrong-but-harmless "" reaches the same honest
# answer instead of this helper duplicating that judgment.
def resolve-run [uid: string, repo: string = ""]: nothing -> string {
    let base = (if ($repo | is-empty) { current-repo } else { $repo })
    let slug = (resolve-project-slug $base)
    let agents_dir = (state-root | path join $slug "agents")
    if not ($agents_dir | path exists) { return "" }
    let matches = (
        ls $agents_dir
        | where type == dir
        | get name
        | each {|d| $d | path basename }
        | where {|run| (($agents_dir | path join $run $uid) | path exists) }
    )
    # `first` is not a tie-break: `mint-uid`/`claim-address` keep a uid unique
    # across the whole project, so at most one run can hold it. It used to be
    # one — two same-role spawns both minted `<role>-1`, and whichever run
    # sorted first got every uid-addressed verb while the other worker stayed
    # live with no address at all (dotfiles-bg65).
    if ($matches | is-empty) { "" } else { $matches | first }
}

# The project a lookup searched, worded for a refusal — the exact same
# derivation `resolve-run` uses, so what a message names is what was actually
# searched rather than a guess at it.
def project-label [repo: string = ""]: nothing -> string {
    let base = (if ($repo | is-empty) { current-repo } else { $repo })
    if ($base | is-empty) { "no project (not inside a git repository)" } else { $base }
}

# `resolve-run`, refused BY NAME the moment a CLI verb sees an unknown uid —
# naming both the uid and the project searched, rather than letting an empty
# run flow downstream into an internal function's own `($run)/($uid)`
# message. Observed live: with an empty run that interpolation reads
# "unknown worker /nobody: ..." — a malformed address that also never says
# WHERE it looked, so a wrong-project miss and a never-spawned uid are
# indistinguishable to an operator. That distinction is the whole point of
# scoping `resolve-run` to one project (sp029 T9) instead of scanning every
# project this user has ever worked in and matching whichever came first.
def resolve-run-or-refuse [verb: string, uid: string, repo: string = ""]: nothing -> string {
    let run = (resolve-run $uid $repo)
    if ($run | is-empty) {
        let project = (project-label $repo)
        error make {msg: $"($verb) refused: unknown worker ($uid) in ($project): no identity recorded there. Absent evidence is not permission to act \(adr0017)"}
    }
    $run
}

# Whose queue/outbox a verb acts as, absent an explicit `--as`. Mirrors
# PI_WORKER_UID, already set on every spawned worker's window (`worker-spawn`).
def self-uid []: nothing -> string { $env | get -o PI_WORKER_UID | default "" }

# Peer-addressed send (sp029 T3/T9): a message to one or more agents' queues,
# opaque content, no run, no sequence. The legacy ticket/instructions work
# payload this verb used to carry retired with the stage registry (T8) — that
# shape lives in `worker-resume`'s own inbox write now, not in a CLI verb.
# `--to` is a comma-separated string, not a nushell list flag: every other
# multi-value CLI flag here (`spawn --task`, the retired `send --artifacts`)
# used the same shape, and it is what a shell (or a subprocess argv built by
# the Pi extension, which cannot hand nu a list literal across several argv
# entries) can pass without ceremony.
def "main send" [--as: string = "", --to: string = "", --content: string = ""] {
    let as_ = (if ($as | is-empty) { self-uid } else { $as })
    if ($as_ | is-empty) {
        error make {msg: "send needs --as: who is sending; pass it explicitly, or run inside a worker window where PI_WORKER_UID is already set"}
    }
    let recipients = ($to | split row "," | each {|a| $a | str trim } | where {|a| $a | is-not-empty })
    if ($recipients | is-empty) {
        error make {msg: "send needs --to: one or more recipient addresses, comma-separated, e.g. --to orchestrator-1"}
    }
    if ($content | is-empty) {
        error make {msg: "send needs --content: the message body; the bus interprets none of it"}
    }
    bus-send --to $recipients --from $as_ --content $content | to json | print
}

# Prints nothing when there is no mail, so `if (pi-worker wait --as me |
# is-empty)` works in a script. Silence is the answer, not an error.
#
# `--as` doubles as both "whose mail" and "who may mark it read" (sp029 T9):
# `wait` is the one verb that WRITES to a queue (it marks every row it returns,
# folding the old `ack` into delivery itself — there is no ack file any more).
# A session that has already claimed an address (PI_WORKER_UID) may still ask
# to observe another agent's mail through `status`/`inspect`, but may not use
# `wait` to consume it: reading AND marking someone else's queue crosses the
# one ownership line this bus enforces.
#
# `--timeout` is in seconds here rather than a duration, because the caller is
# usually a model writing flags and `--timeout 30` is harder to get wrong than
# `--timeout 30sec`.
def "main wait" [--as: string = "", --block, --timeout: int = 60] {
    let as_ = (if ($as | is-empty) { self-uid } else { $as })
    if ($as_ | is-empty) {
        error make {msg: "wait needs --as: whose queue to read; pass it explicitly, or run inside a worker window where PI_WORKER_UID is already set"}
    }
    let self = (self-uid)
    if ($self | is-not-empty) and ($self != $as_) {
        error make {msg: $"wait refused: --as ($as_) is not this session's own address \(($self)); reading and marking another agent's mail crosses an ownership line. Use `status`/`inspect` to observe it instead"}
    }
    let mail = (bus-wait --as $as_ --block=$block --timeout ($timeout * 1sec))
    if ($mail | is-not-empty) {
        for m in $mail { queue-mark-read $as_ $m.id }
        print ($mail | to json)
    }
}

# The worker's own side of the bus (dotfiles-87bt).
#
# `bus-result` and the settle reporter had no CLI surface, and the extension
# registered no tool, so a worker had no way to report an outcome by ANY route
# while work-do/SKILL.md instructed it to "finish by calling the typed result
# tool". These two verbs are that path. The extension's typed tool is a thin
# wrapper over `result`, so the envelope shape and the stage gate have exactly
# one implementation instead of one per runtime.
def "main result" [--as: string = "", --status: string = "", --summary: string = "", --validation: string = ""] {
    # A worker reports from inside the window spawn made for it, and spawn put
    # PI_WORKER_UID in that window's environment. Making the worker pass its
    # own address back is ceremony, and a worker that gets it wrong reports
    # onto someone else's mail.
    let as_ = (if ($as | is-empty) { self-uid } else { $as })
    require-flags "result" [
        [flag, value, what];
        ["--as" $as_ "who is reporting. Omit it inside a worker window: PI_WORKER_UID is already there"]
        ["--status" $status $"the outcome, one of ($RESULT_STATUSES | str join ', ')"]
        ["--summary" $summary "what happened, in a line or two; detail belongs in the worker window and the Pi transcript"]
    ]
    let run = (resolve-run-or-refuse "result" $as_)
    # The worker supplies its OUTCOME; window, session and resume come from the
    # identity the orchestrator recorded at spawn. A worker cannot be trusted to
    # say where it lives or how to reach it — that is the initiator's only route
    # back to it, and a worker that could rewrite it could point the initiator
    # at someone else's session.
    let identity = (bus-identity-of $as_ --run $run)
    if $identity == null {
        error make {msg: $"refusing a result from ($as_): no identity on the bus, so there is nothing to report against"}
    }

    let base = {
        status: $status
        summary: $summary
        window: $identity.window
        session: $identity.session
        resume: $"pi --session ($identity.session)"
    }
    # An absent verdict must stay ABSENT rather than become "": the gate reads
    # emptiness, and a present-but-empty field is the shape a caller uses to
    # look compliant without having validated anything.
    let payload = (if ($validation | is-empty) { $base } else { $base | merge {validation: $validation} })
    bus-result $as_ --run $run --result $payload | to json | print
}

def "main settled" [--as: string = ""] {
    let as_ = (if ($as | is-empty) { self-uid } else { $as })
    if ($as_ | is-empty) {
        error make {msg: "settled needs --as: which agent settled. Omit it inside a worker window: PI_WORKER_UID is already there"}
    }
    let run = (resolve-run-or-refuse "settled" $as_)
    bus-settled $as_ --run $run | to json | print
}

# The tmux-side probe, kept OFF `inspect` and `status` on purpose: those two
# rebuild a worker from the bus alone, without tmux, which is what lets a
# restarted initiator recover. This verb is the one that needs a display host,
# so it is the one that carries the --socket. Free to observe ANY uid — the
# ownership line `wait` enforces is about marking mail read, not about looking.
def "main liveness" [uid: string, --socket: string = ""] {
    let run = (resolve-run-or-refuse "liveness" $uid)
    let identity = (bus-identity-of $uid --run $run)
    if $identity == null {
        error make {msg: $"unknown worker ($uid): no identity on the bus. Absent evidence is not permission to act \(adr0017)"}
    }
    # Probe by id (unambiguous), report the NAME (what an operator scans a
    # window list for), and carry the id so a caller can act on it.
    let seen = (worker-liveness (window-target $identity) --socket $socket)
    $seen | merge {window: $identity.window, window_id: ($identity | get -o window_id | default "")} | to json | print
}

def "main status" [uid: string] {
    let run = (resolve-run $uid)
    bus-status $uid --run $run | to json | print
}
def "main inspect" [uid: string] {
    let run = (resolve-run-or-refuse "inspect" $uid)
    worker-inspect $uid --run $run | to json | print
}
# A table by default, JSON on request.
#
# Every other verb answers a machine, so JSON was the obvious default here too
# — and it is the wrong one. This verb exists to be READ: a human asking where
# a worker's time went, handed 60 lines of pretty-printed JSON, has been given
# the data and not the answer. The extension asks for --json; a person at a
# prompt gets columns.
def "main timeline" [uid: string, --json] {
    let run = (resolve-run $uid)
    let events = (worker-timeline $uid --run $run)
    if $json {
        $events | to json | print
    } else if ($events | is-empty) {
        print $"no events recorded for ($uid) in this project"
    } else {
        $events | select "+s" event state detail | print
    }
}
def "main rm" [--uid: string = ""] {
    require-flags "rm" [[flag, value, what]; ["--uid" $uid $UID_IS]]
    let run = (resolve-run $uid)
    worker-release --run $run --uid $uid | to json | print
}

def "main ps" [--socket: string = ""] {
    worker-roster --run "" --socket $socket | to json | print
}

# Every worker in the CURRENT PROJECT, from the bus alone — no tmux, so this is
# what a restarted initiator reconstructs from. `--run` used to scope this to
# one caller-minted run; every run under the runtime bus tree is now read and
# flattened, since the project (derived, never typed) is the only scope a CLI
# caller has left to ask for.
def "main workers" [] {
    let root = (bus-root)
    let runs = (if ($root | path exists) {
        ls $root | where type == dir | get name | each {|d| $d | path basename }
    } else { [] })
    ($runs | each {|r| run-workers $r } | flatten) | to json | print
}

def "main resume" [uid: string, --feedback: string = "", --socket: string = ""] {
    require-flags "resume" [
        [flag, value, what];
        ["--feedback" $feedback "what the worker got wrong and what to do instead; it reaches its inbox as an ordinary message"]
    ]
    let run = (resolve-run-or-refuse "resume" $uid)
    worker-resume $uid --run $run --feedback $feedback --socket $socket | to json | print
}

# The repository a verb works in: what the caller passed, or where it stands.
#
# Observed live, on the operator's screen:
#
#     accept refused: Can't convert to string.
#
# `--repo` was declared `string` with no default in accept, respawn and
# reclaim, so omitting it propagated a NULL inward until expand-path died on
# it. `main spawn` documents that exact failure and guards against it; these
# three never got the same treatment, and the message names no verb, no flag
# and no remedy — the operator watched a `complete` worker sit in the frame
# while its orchestrator retried.
#
# Derived rather than demanded, for the same reason spawn derives it: which
# repository the caller is standing in is not a decision it was making. When
# there is nothing to derive, the refusal names the flag and what it is for.
#
# Resolved BEFORE the bus is asked anything, so a caller error is reported as
# one instead of surfacing four calls deeper.
def repo-or-refuse [verb: string, repo: any]: nothing -> string {
    let given = (if $repo == null { "" } else { $repo })
    let resolved = (if ($given | is-empty) { current-repo } else { $given })
    if ($resolved | is-empty) {
        error make {msg: $"($verb) needs --repo: the git repository the worker works in. Normally derived from the current directory — pass it only when that is not a repository"}
    }
    $resolved
}

def "main respawn" [uid: string, --repo: string, --socket: string = ""] {
    let repo = (repo-or-refuse "respawn" $repo)
    let run = (resolve-run-or-refuse "respawn" $uid $repo)
    worker-respawn $uid --run $run --repo $repo --socket $socket | to json | print
}

def "main accept" [uid: string, --repo: string, --socket: string = ""] {
    let repo = (repo-or-refuse "accept" $repo)
    let run = (resolve-run-or-refuse "accept" $uid $repo)
    worker-accept $uid --run $run --repo $repo --socket $socket | to json | print
}

def "main stop" [uid: string, --socket: string = ""] {
    let run = (resolve-run-or-refuse "stop" $uid)
    worker-stop $uid --run $run --socket $socket | to json | print
}

def "main reclaim" [
    --repo: string, --base: string = "", --socket: string = "", --remote: string = ""
    --force, --dry-run
] {
    let repo = (repo-or-refuse "reclaim" $repo)
    (worktrees-reclaim --repo $repo --base $base --socket $socket --remote $remote
        --force=$force --dry-run=$dry_run) | to json | print
}

# Report on each dependency SEPARATELY. A single "something is missing" tells
# an operator nothing they can act on; naming the one that is absent turns a
# support question into a one-line fix.
def "main doctor" [] {
    let checks = [
        {
            name: "nushell"
            ok: true
            detail: $"($nu.current-exe) (version | get version)"
        }
        {
            name: "tmux"
            ok: ((do { ^tmux -V } | complete | get exit_code) == 0)
            detail: (do { ^tmux -V } | complete | get stdout | str trim)
        }
        {
            name: "XDG_RUNTIME_DIR"
            ok: (($env | get -o XDG_RUNTIME_DIR | default "" | is-not-empty))
            detail: ($env | get -o XDG_RUNTIME_DIR | default "unset — export it, e.g. /run/user/$(id -u)")
        }
        {
            name: "pi"
            ok: ((do { ^pi --version } | complete | get exit_code) == 0)
            detail: (do { ^pi --version } | complete | get stdout | str trim)
        }
    ]
    for c in $checks {
        let mark = (if $c.ok { "ok  " } else { "MISS" })
        print $"($mark) ($c.name): ($c.detail)"
    }
    if ($checks | where {|c| not $c.ok and $c.name != "pi" } | is-not-empty) {
        # `pi` absent is fine on a Claude-only box; the rest are not.
        error make {msg: "required dependencies are missing (see MISS lines above)"}
    }
}
