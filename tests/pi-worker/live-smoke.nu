#!/usr/bin/env nu
# live-smoke — the live-Pi run of the peer-addressed worker bus (sp029 T11).
#
#   nu tests/pi-worker/live-smoke.nu
#   nu tests/pi-worker/live-smoke.nu --only peer,human,brainstorm --timeout 120
#
# NOT part of `run-tests.nu`, and not a merge gate. That suite proves the
# protocol on any machine, every time, with a stub in place of Pi. This script
# is the other half the suite's own header admits it cannot be: real Pi
# agents, in real tmux windows, in a real worktree of this repo, spending real
# tokens. Run it when the bus itself changes — spawn, send, wait, result,
# delivery, resume, teardown — and read the suite for everything else.
#
# It costs money and a few minutes per run. Nothing else here does, which is
# why it is opt-in and why it says so this loudly.
#
# sp029 rebuilt ft014 from a run/uid-addressed star (one privileged initiator)
# into a peer-addressed bus (every agent is an address). T1-T10 proved that
# rebuild against a stub `pi` and a fake host API — real, careful coverage,
# but coverage of a MODEL of the extension, never the extension itself wired
# to a real running Pi. This script is the first thing that runs the real
# wiring end to end, and its most important job is reporting what it finds
# rather than what the design says should happen ([[sp025]]'s [[poc021]]:
# soft claims are inert, only behavior counts).
#
# ---------------------------------------------------------------- KNOWN GAP
#
# The very first live run against this rewrite (2026-09-10) found that the
# transport does not do what its own consumer docs
# (plan-scrum-master/SKILL.md's dispatch table, brainstorm-stage.md) assume:
# `pi-worker send --to <uid>` never reaches a worker `spawn` created, in
# EITHER `--isolation worktree` or `--isolation main`. A spawned worker's
# extension activation starts `createInboxWatcher`, bound to the LEGACY
# `run/<uid>/inbox/*.json` path; `send`/`bus-send` write only to the NEW
# `bus/queue/<uid>` + `bus/messages/<id>`, which only a SELF-REGISTERED
# session's `createBusWatcher` ever reads (pi.ts:648-652 documents the split
# as deliberate — "a session with PI_WORKER_UID set behaves as today"). A
# self-registered session's claimed address is in turn never surfaced to the
# model, any tool, any log line, or any bus/state file, so nothing can learn
# it to address a message back. Net effect: there is currently no live,
# working path for an external sender to reach EITHER kind of addressable
# agent via the documented `send --to` verb. Filed as dotfiles-uddc (P0).
#
# `pi-worker resume <uid> --feedback` IS confirmed live-functional (it writes
# the same legacy inbox a spawned worker's watcher actually reads), so the
# phases below use it as the one proven-working injection channel where a
# real message must reach a real spawned worker, and separately, honestly,
# demonstrate the `send --to` gap live rather than routing around it quietly.
#
# ------------------------------------------------------------------ reporting

def step [msg: string] { print $"(ansi cyan)→(ansi reset) ($msg)" }

def check [ok: bool, msg: string] {
    if $ok {
        print $"  (ansi green)ok(ansi reset)   ($msg)"
    } else {
        print $"  (ansi red)FAIL(ansi reset) ($msg)"
        error make {msg: $"check failed: ($msg)"}
    }
}

def check-eq [actual, expected, msg: string] {
    if $actual == $expected {
        print $"  (ansi green)ok(ansi reset)   ($msg)"
    } else {
        print $"  (ansi red)FAIL(ansi reset) ($msg)"
        print $"       expected: ($expected | to nuon)"
        print $"       actual:   ($actual | to nuon)"
        error make {msg: $"check failed: ($msg). expected ($expected | to nuon), got ($actual | to nuon)"}
    }
}

# A finding is not a failure: it is a fact this run observed and is recording
# on purpose, per its own charter above ("recorded... not a test failure to
# be edited away"). Printed distinctly from `check` so a reader scanning
# output never mistakes "this is what happened" for "this is broken code in
# the smoke script".
def finding [msg: string] {
    print $"  (ansi yellow)FINDING(ansi reset) ($msg)"
}

# ------------------------------------------------------------------- the CLI
#
# Driven as an operator drives it, through the installed `pi-worker` rather
# than by importing the module for ACTIONS (dotfiles-87bt: a case that called
# the module directly proved a headline claim against a path no caller could
# take). Read-only bus/queue inspection below goes through the module
# directly instead — see `use` below — because that IS the honest way to
# assert "from the BUS", never from pane content.

def cli-raw [args: list<string>]: nothing -> record {
    do { ^pi-worker ...$args } | complete
}

def cli [args: list<string>]: nothing -> any {
    let out = (cli-raw $args)
    if $out.exit_code != 0 {
        error make {msg: $"pi-worker ($args | str join ' ') failed: ($out.stderr | str trim)"}
    }
    let text = ($out.stdout | str trim)
    if ($text | is-empty) { return null }
    $text | from json
}

use harness.nu [pane-text, settled-pane-text, assert-pane-unchanged]
use ../../claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu [queue-rows, project-dir]

# ------------------------------------------------------------------- fixture

# The MAIN worktree, replicating `main-worktree`'s own algorithm rather than
# a bare `git rev-parse --show-toplevel` (T1's whole point): this script may
# itself be invoked from a nested worktree, and `--show-toplevel` there
# answers with the NESTED tree, which would place every spawned worker's
# `.worktrees/wk-*` one level inside someone else's task worktree instead of
# alongside it in the repo everyone actually shares.
def main-worktree-of [repo: string]: nothing -> string {
    let common = (do { ^git -C $repo rev-parse --path-format=absolute --git-common-dir } | complete)
    if $common.exit_code != 0 {
        error make {msg: $"cannot resolve the git directory for ($repo): ($common.stderr | str trim)"}
    }
    let dir = ($common.stdout | str trim)
    if ($dir | str ends-with "/.git") { $dir | path dirname } else { $repo }
}

# Every message CURRENTLY on the bus addressed `from` -> a member of `to`,
# whose content matches `content` exactly. Read-only: opens only
# `bus/messages/<id>` for ids a queue row already named, exactly like the
# module's own `bus-wait` does — never a directory listing used as a search.
def find-message [from: string, to: string, content: string]: nothing -> any {
    let rows = (queue-rows $to)
    for row in $rows {
        let path = (project-dir | path join "messages" $row.id)
        if ($path | path exists) {
            let envelope = (open --raw $path | from json)
            if $envelope.from == $from and ($to in $envelope.to) and $envelope.content == $content {
                return ($envelope | merge {read: $row.read})
            }
        }
    }
    null
}

# ------------------------------------------------------------------ teardown

# Only what THIS run spawned, addressed by the ids its own spawns reported —
# never a name, never a pattern over the window list.
def reap [w: record, repo: string] {
    do { ^tmux kill-window -t $w.window_id } | complete | ignore
    # isolation=main never allocated a worktree or branch: its cwd IS the
    # repo, and removing "the repo" here would be catastrophic rather than
    # a cleanup. Only a worktree-isolated worker gets git surgery.
    if $w.isolation == "worktree" {
        if ($w.cwd | path exists) {
            do { ^git -C $repo worktree remove --force $w.cwd } | complete | ignore
        }
        do { ^git -C $repo branch -D $w.branch } | complete | ignore
    }
    cli-raw ["stop" $w.uid] | ignore
    cli-raw ["rm" "--uid" $w.uid] | ignore
}

def reap-all [workers: list<record>, repo: string] {
    print ""
    step "teardown"
    for w in $workers { reap $w $repo }
    let uids = ($workers | get uid)
    let left = (cli ["workers"] | default [] | where {|w| $w.uid in $uids })
    if ($left | is-empty) {
        print $"  (ansi green)ok(ansi reset)   released ($uids | length) worker\(s\): no worktree, branch or window left behind"
    } else {
        error make {msg: $"($left | length) of this run's workers are still on the bus after teardown: ($left | get uid | str join ', ')"}
    }
}

# ---------------------------------------------------------------------- main

# The brainstorm stage instruction, copied verbatim from
# claude/marketplace/plugins/infinifu/skills/plan-scrum-master/references/brainstorm-stage.md
# ("Why the instruction is copied here in full, not linked" — sp025/poc021:
# a link or a skill name is soft guidance, and soft guidance is inert).
const BRAINSTORM_INSTRUCTION = "You are running a brainstorm stage. A human is at this window's other end —
not on the message bus, not reachable by any other agent, only here. Talk
with them until the two of you have actually reached a decision, or until you
are certain no decision is coming.

You decide when this conversation is finished. Not the human saying a
magic word, not a message count, not a timer — your own judgment that the
question has been answered or that it plainly will not be. When you decide,
report a typed result and stop — it is addressed automatically to whoever
commissioned you, so you never need to name them yourself:

    pi-worker result --as <your-uid> --status <status> --summary \"<summary>\" [--validation \"<validation>\"]

`--status` is one of:
  - complete       — you and the human reached an explicit decision. --validation
                      is REQUIRED and must name what makes you sure it is a
                      decision and not your own preference (a direct quote or
                      an explicit yes, never \"seemed reasonable\").
  - waiting_human  — still needs the human: they have gone quiet, or a
                      question is still open. This is what \"waiting_human\"
                      has always meant here: a human is needed AT THIS WINDOW,
                      never that mail is waiting for someone on the bus.
  - blocked        — the conversation reached a real obstacle that is not a
                      human-input gap (contradictory constraints, a decision
                      that needs someone else entirely).
  - failed         — the conversation cannot produce what it was commissioned
                      for.

Never report `complete` to look finished. If the conversation is
inconclusive, ambiguous, or the human never confirmed anything, that is
`waiting_human` or `blocked` with an honest summary of where it stands — NOT
`complete` with a summary that papers over the gap. A short, honest
`waiting_human` is correct output; a fabricated `complete` is not, no matter
how long you have been at this.

You may NOT decide these on your own — each needs an explicit, stated answer
from the human before you may treat it as settled. Absence of a stated
preference is not permission to pick a default and move on:

  1. Whether the design or approach is APPROVED enough to report `complete`.
     Your own recommendation is not an approval. Only the human's explicit
     agreement is.
  2. Any file format, schema/data shape, library, dependency, or naming
     choice the human has not stated. Silence on one of these is not a
     decision — surface it and ask, or report the conversation as still open.
  3. Scope boundaries: what is in and what is out of what gets built next.
     Confirm explicitly; never infer from what the human didn't object to.
  4. Anything with an effect outside this conversation: writing a file,
     creating a ticket, running a command, spawning another agent. Never do
     any of this during a brainstorm — that is a later stage's job, and you
     report a decision for that stage to act on, not act on it yourself.

If the human stops responding, wait. Do not fill the silence by inventing
what they would probably have said. A commissioner asking you for a status
mid-conversation gets `waiting_human` and an honest one-line account of where
the conversation paused — never a summary that pretends the human weighed in
on a point they never touched."

def main [
    --only: string = "peer,human,brainstorm"   # comma list: which phases to run
    --repo: string = ""
    --timeout: int = 90            # seconds to wait for any one live turn
    --keep                         # leave workers/trees/windows for inspection on failure
] {
    print $"(ansi cyan)pi-worker live smoke(ansi reset) — real Pi workers, real tokens"
    print ""

    step "preflight"
    for dep in ["pi-worker" "pi" "tmux" "git"] {
        check ((which $dep | length) > 0) $"($dep) on PATH"
    }
    let repo = (if ($repo | is-empty) {
        let top = (do { ^git rev-parse --show-toplevel } | complete)
        check ($top.exit_code == 0) "run from inside a git repository, or pass --repo"
        main-worktree-of ($top.stdout | str trim)
    } else {
        main-worktree-of $repo
    })
    print $"  (ansi grey)project: ($repo)(ansi reset)"

    # `pi auth check` needs --provider or --model; with neither it exits
    # nonzero but still prints its own usage, which is not what this preflight
    # is asking. What matters here is whatever `spawn` will actually use,
    # which is a settings.json default this script does not own — so this
    # step just confirms the DEPENDENCY chain (pi itself answers), and leaves
    # provider readiness to be discovered as a spawn failure if it is wrong,
    # with spawn's own error naming what happened.
    check ((do { ^pi --version } | complete | get exit_code) == 0) "pi answers --version"

    let phases = ($only | split row "," | each {|p| $p | str trim })
    let tag = (random chars --length 5 | str lowercase)
    let worktrees_before = (^git -C $repo worktree list | lines)

    mut all_workers = []
    mut failures = []

    # ------------------------------------------------------- phase: peer
    if "peer" in $phases {
        print ""
        step "phase: two peers addressing each other directly"
        let outcome = (try {
            # Explicit --uid on every spawn below. It is no longer a
            # workaround — dotfiles-bg65 made minting project-wide, so two
            # ordinary `--role peer` spawns now take two addresses rather than
            # both minting `peer-1` (which is what this script found the first
            # time it ran, leaving one peer reachable by nothing but `rm -rf`).
            # The tagged names stay because THIS script names the peers to each
            # other in its instructions, and `peer-a-<tag>` reads better in a
            # transcript than whatever number the project's counter is on.
            let a = (cli ["spawn" "--uid" $"peer-a-($tag)" "--role" "peer" "--subject" $"smoke-peer-a-($tag)" "--skill" "smoke-peer" "--isolation" "worktree" "--repo" $repo])
            let b = (cli ["spawn" "--uid" $"peer-b-($tag)" "--role" "peer" "--subject" $"smoke-peer-b-($tag)" "--skill" "smoke-peer" "--isolation" "worktree" "--repo" $repo])
            $all_workers = ($all_workers | append [$a $b])
            check ($a.liveness == "live") $"($a.uid) is live in ($a.window)"
            check ($b.liveness == "live") $"($b.uid) is live in ($b.window)"
            print $"  (ansi grey)($a.uid) <-> ($b.uid)(ansi reset)"

            # The documented flow (plan-scrum-master/SKILL.md's dispatch
            # table): the operator tells each peer who the other is and what
            # to do, addressed directly, no relay. Sent in full even though
            # KNOWN_GAP above predicts it will not arrive — this IS the check
            # for whether that gap is still present, and it must keep asking
            # the real question rather than a weakened one.
            let instr_a = $"sp029 live smoke: you are peer-addressed as `($a.uid)`. Your peer is `($b.uid)`. Steps, using `pi-worker` \(bash or your pi_worker tool; --as is not needed, PI_WORKER_UID is already yours\): 1\) send ($b.uid) content exactly `ping-1-($tag)`. 2\) when a message from ($b.uid) arrives, append its exact content as a line to smoke-log.md in this worktree's root \(create if absent\), commit \(message 'smoke: round 1'\). 3\) send ($b.uid) content exactly `ping-2-($tag)`. 4\) when a second message from ($b.uid) arrives, append it as a second line to smoke-log.md, commit \(message 'smoke: round 2'\). 5\) once smoke-log.md has exactly two committed lines, call `pi-worker result --status complete --summary \"exchanged 2 rounds with ($b.uid)\" --validation \"smoke-log.md has 2 committed lines: pong-1-($tag) then pong-2-($tag)\"`. Do nothing else."
            let instr_b = $"sp029 live smoke: you are peer-addressed as `($b.uid)`. Your peer is `($a.uid)`. Steps: 1\) when a message from ($a.uid) arrives \(content ping-1-($tag)\), append its exact content as a line to smoke-log.md in this worktree's root \(create if absent\), commit \(message 'smoke: round 1'\), then send ($a.uid) content exactly `pong-1-($tag)`. 2\) when a second message from ($a.uid) arrives \(ping-2-($tag)\), append it as a second line, commit \(message 'smoke: round 2'\), then send ($a.uid) content exactly `pong-2-($tag)`. 3\) once done, call `pi-worker result --status complete --summary \"exchanged 2 rounds with ($a.uid)\" --validation \"smoke-log.md has 2 committed lines: ping-1-($tag) then ping-2-($tag)\"`. Do nothing else."

            cli ["send" "--as" "smoke-operator" "--to" $a.uid "--content" $instr_a] | ignore
            cli ["send" "--as" "smoke-operator" "--to" $b.uid "--content" $instr_b] | ignore

            # A bounded 20s here, not `--timeout`: this wait is asking whether
            # a WATCHER polling once a second ever picks the row up, not
            # waiting on real model latency — 20s is ample either way, and
            # not scaling it with `--timeout` keeps a doomed-by-dotfiles-uddc
            # wait from eating the same budget the other two phases need for
            # an actual model turn.
            let peer_wait: duration = 20sec
            step $"waiting up to ($peer_wait) for the exchange the BUS should show"
            let deadline = ((date now) + $peer_wait)
            mut delivered = false
            while (date now) < $deadline {
                let a_log = ($a.cwd | path join "smoke-log.md")
                let b_log = ($b.cwd | path join "smoke-log.md")
                if ($a_log | path exists) and ($b_log | path exists) {
                    let a_lines = (open --raw $a_log | lines | where {|l| $l | is-not-empty })
                    let b_lines = (open --raw $b_log | lines | where {|l| $l | is-not-empty })
                    if ($a_lines | length) >= 2 and ($b_lines | length) >= 2 { $delivered = true; break }
                }
                sleep 2sec
            }

            if $delivered {
                # The real assertions this criterion asks for: from the BUS
                # (a resolvable message matching exactly what was sent, for
                # each of the four), and from each agent's OWN tree — never
                # from pane content.
                for pair in [[$a.uid, $b.uid, $"ping-1-($tag)"], [$a.uid, $b.uid, $"ping-2-($tag)"], [$b.uid, $a.uid, $"pong-1-($tag)"], [$b.uid, $a.uid, $"pong-2-($tag)"]] {
                    let msg = (find-message $pair.0 $pair.1 $pair.2)
                    check ($msg != null) $"the bus resolves ($pair.2) from ($pair.0) to ($pair.1)"
                }
                check-eq (open --raw ($a.cwd | path join "smoke-log.md") | lines | where {|l| $l | is-not-empty }) [$"pong-1-($tag)" $"pong-2-($tag)"] "a's own tree recorded b's two replies, in order"
                check-eq (open --raw ($b.cwd | path join "smoke-log.md") | lines | where {|l| $l | is-not-empty }) [$"ping-1-($tag)" $"ping-2-($tag)"] "b's own tree recorded a's two pings, in order"
                print $"(ansi green)peer exchange delivered live(ansi reset) — dotfiles-uddc appears resolved; update this script's KNOWN GAP header"
            } else {
                # The documented, expected-per-current-defect outcome. Recorded
                # with full bus evidence rather than silently skipped or
                # loosened into something that would pass either way.
                let a_rows = (queue-rows $a.uid)
                let b_rows = (queue-rows $b.uid)
                finding $"neither peer received the other's `send --to` within ($peer_wait) \(dotfiles-uddc: a spawned worker's watcher reads the legacy run/uid inbox, not the new bus/queue/<uid> `send` writes to\)"
                finding $"($a.uid)'s queue: ($a_rows | to json -r); ($b.uid)'s queue: ($b_rows | to json -r) — rows exist \(fan-out worked\), none read \(no watcher consumed them\)"
                check false $"two live peers exchange 4 messages without a relay within ($peer_wait) \(blocked live by dotfiles-uddc — see KNOWN GAP\)"
            }
            null
        } catch {|e| $e})
        if $outcome != null { $failures = ($failures | append {phase: "peer", error: $outcome.msg}) }
    }

    # ------------------------------------------------------ phase: human
    if "human" in $phases {
        print ""
        step "phase: delivery into a session a human is attending"
        let outcome = (try {
            let c = (cli ["spawn" "--uid" $"human-c-($tag)" "--role" "peer" "--subject" $"smoke-human-($tag)" "--skill" "smoke-human" "--isolation" "worktree" "--repo" $repo])
            $all_workers = ($all_workers | append $c)
            check ($c.liveness == "live") $"($c.uid) is live in ($c.window)"

            # `send --to` cannot reach a spawned worker live (KNOWN GAP,
            # dotfiles-uddc). `resume --feedback` writes the SAME legacy
            # inbox the worker's watcher actually polls, through the SAME
            # `decideDelivery`/`sendUserMessage` code every delivery path
            # shares — confirmed live-functional — so it is what this phase
            # uses to get a real message into a real idle session.
            step "priming: establish a logging convention, confirm the worker goes idle"
            cli-raw ["resume" $c.uid "--feedback" "Whenever a NEW message arrives in this session from now on, including this one, append its exact text as a new line to received.md in this worktree's root (create the file if absent) and `git commit` it (message: 'smoke: logged message'). After logging THIS message, do nothing else — wait idle for the next one."] | ignore
            let received = ($c.cwd | path join "received.md")
            let prime_deadline = ((date now) + ($timeout * 1sec))
            mut primed = false
            while (date now) < $prime_deadline {
                if ($received | path exists) { $primed = true; break }
                sleep 3sec
            }
            check $primed $"($c.uid) logged the priming message to received.md within (($timeout))s"

            step "round 1: a human mid-keystroke, then an injected message"
            ^tmux send-keys -t $c.window_id "I am halfway through typing my own though"
            let before = (settled-pane-text "" $c.window_id --deadline 10sec)
            check ($before | str contains "I am halfway through typing my own though") "the human's unsubmitted keystrokes are visible before injection"

            let ping1 = $"peer-ping-while-typing-($tag)"
            cli-raw ["resume" $c.uid "--feedback" $ping1] | ignore
            let deadline1 = ((date now) + ($timeout * 1sec))
            mut got1 = false
            while (date now) < $deadline1 {
                if ($received | path exists) and (open --raw $received | str contains $ping1) { $got1 = true; break }
                sleep 2sec
            }
            let after = (pane-text "" $c.window_id)
            let preserved = ($after | str contains "I am halfway through typing my own though")
            let outcome1_label = (if $got1 { "delivered — received.md logged it" } else { "NOT delivered within timeout — see received.md/queue state above" })
            let preserved_label = (if $preserved { "still visible verbatim" } else { "no longer visible" })
            finding $"outcome: ($outcome1_label)"
            finding $"the human's unsubmitted text was ($preserved_label) in the pane after injection"
            check $got1 $"the injected message reached ($c.uid) \(from BUS/tree, not pane\) within (($timeout))s"

            step "round 2: the same injection while the worker is genuinely mid-turn"
            cli-raw ["resume" $c.uid "--feedback" "When you receive the NEXT message after this one, first run `sleep 10` via your bash tool, THEN log it exactly like before (append its exact text as a new line to received.md and commit). This message itself needs no action beyond remembering the instruction."] | ignore
            sleep 3sec
            let ping2 = $"peer-ping-mid-turn-($tag)"
            cli-raw ["resume" $c.uid "--feedback" $ping2] | ignore
            # Sampled a few seconds in, while the `sleep 10` is almost
            # certainly still running: the message must not have been folded
            # in ahead of the busy turn it interrupted.
            sleep 4sec
            let mid_turn_seen_early = (($received | path exists) and (open --raw $received | str contains $ping2))
            let deadline2 = ((date now) + ($timeout * 1sec))
            mut got2 = false
            while (date now) < $deadline2 {
                if ($received | path exists) and (open --raw $received | str contains $ping2) { $got2 = true; break }
                sleep 2sec
            }
            let early_label = (if $mid_turn_seen_early { "already visible 4s in — did NOT wait for the busy turn" } else { "correctly absent while busy" })
            finding $"mid-turn injection: ($early_label); eventually delivered: ($got2)"
            check (not $mid_turn_seen_early) "a message sent while the worker is mid-turn is not folded in ahead of the turn it interrupted"
            check $got2 $"the mid-turn message is not lost — it lands once ($c.uid) returns to idle, within (($timeout))s of the busy turn finishing"
            null
        } catch {|e| $e})
        if $outcome != null { $failures = ($failures | append {phase: "human", error: $outcome.msg}) }
    }

    # ------------------------------------------------- phase: brainstorm
    if "brainstorm" in $phases {
        print ""
        step "phase: brainstorm agent, a human, and its commissioner"
        let before_status = (^git -C $repo status --porcelain | str trim)
        let outcome = (try {
            let d = (cli ["spawn" "--uid" $"brainstorm-d-($tag)" "--role" "brainstorm" "--subject" $"smoke-brainstorm-($tag)" "--skill" "idea-brainstorming" "--isolation" "main" "--repo" $repo])
            $all_workers = ($all_workers | append $d)
            check ($d.liveness == "live") $"($d.uid) is live in ($d.window)"
            check-eq $d.cwd $repo "an --isolation main worker's window opens IN the shared main worktree, not a copy"

            let question = $"The question to brainstorm: for a smoke-test placeholder variable, should we name it `foo` or `bar`? Ask the human directly and wait for their explicit answer before concluding anything."
            let instruction = ($BRAINSTORM_INSTRUCTION + "\n\n" + $question)
            # KNOWN GAP again: `send --as $d.run --to $d.uid` is the documented
            # call (brainstorm-stage.md) and does not arrive live. `resume`
            # is the proven substitute for getting the FIRST message in.
            cli-raw ["resume" $d.uid "--feedback" $instruction] | ignore

            # A polling loop, not `settled-pane-text`: the agent is actively
            # streaming a turn (a spinner, tool-call renders, skill loading),
            # so the pane never stops changing for the quiet window that
            # helper waits for — it would sample whatever the pane happened
            # to show at one instant, which is exactly the pane-content
            # dependence the OTHER phases avoid, and it caught itself here
            # live: a first run's "settled" snapshot landed mid skill-load,
            # well before any question was asked.
            step "waiting for the agent to ask the human something"
            let ask_deadline = ((date now) + ($timeout * 1sec))
            mut asked = ""
            mut got_question = false
            while (date now) < $ask_deadline {
                $asked = (pane-text "" $d.window_id)
                if ($asked | str contains "?") or ($asked | str contains "foo") or ($asked | str contains "bar") { $got_question = true; break }
                sleep 2sec
            }
            check $got_question $"the brainstorm agent said something resembling a question, live, within (($timeout))s"

            step "the human answers, live, at the pane"
            ^tmux send-keys -t $d.window_id "bar" Enter

            step $"waiting up to (($timeout))s for the typed result at the commissioner's address"
            let result = (cli ["wait" "--as" $d.run "--block" "--timeout" ($timeout | into string)])
            check ($result != null) $"($d.uid)'s commissioner \(this script, address ($d.run)\) received a typed result"
            let content = ($result | first | get content)
            print $"  (ansi grey)status=($content.status) summary=($content.summary)(ansi reset)"
            check ($content.status in ["complete" "waiting_human" "blocked" "failed"]) "the result carries one of the four documented statuses, verbatim"
            if $content.status == "complete" {
                check (($content | get -o validation | default "" | is-not-empty)) "a `complete` brainstorm result carries a non-empty validation (adr0027)"
                finding $"brainstorm concluded complete: ($content.summary) / validation: ($content | get -o validation | default '')"
                # The commissioner's next step, actually running, live: this
                # script (the commissioner) acts on the typed field, not on a
                # transcript re-read or an assumption.
                print $"  (ansi cyan)commissioner's next step:(ansi reset) proceeding with decision '($content.summary)' — printed here in lieu of a real pipeline stage, per the spec's own case"
            } else {
                finding $"brainstorm did not conclude complete \(status: ($content.status)\) — an honest non-answer is itself a valid, non-failing outcome per brainstorm-stage.md"
            }

            let after_status = (^git -C $repo status --porcelain | str trim)
            check-eq $after_status $before_status "the brainstorm agent left the shared main worktree exactly as it found it (no writes, no commits)"
            null
        } catch {|e| $e})
        if $outcome != null { $failures = ($failures | append {phase: "brainstorm", error: $outcome.msg}) }
    }

    # ---------------------------------------------------------- cleanup
    if $keep and ($failures | is-not-empty) {
        print ""
        print $"(ansi yellow)--keep + a failure:(ansi reset) leaving ($all_workers | length) worker\(s\) in place for inspection."
        for w in $all_workers {
            let tree_cleanup = (if $w.isolation == "worktree" {
                $"git -C ($repo) worktree remove --force ($w.cwd); git -C ($repo) branch -D ($w.branch); "
            } else { "" })
            print $"  ($w.uid): pi-worker stop ($w.uid); ($tree_cleanup)pi-worker rm --uid ($w.uid)"
        }
    } else if ($all_workers | is-not-empty) {
        reap-all $all_workers $repo
    }

    step "final verification: bus and worktree list re-read"
    let worktrees_after = (^git -C $repo worktree list | lines)
    check-eq $worktrees_after $worktrees_before "git worktree list is unchanged from before this run"
    let uids = ($all_workers | get uid)
    let still_on_bus = (cli ["workers"] | default [] | where {|w| $w.uid in $uids })
    check ($still_on_bus | is-empty) "none of this run's uids remain on the bus"

    print ""
    if ($failures | is-empty) {
        print $"(ansi green)live smoke passed(ansi reset) — ($phases | str join ', ') / tag ($tag)"
    } else {
        print $"(ansi red)live smoke recorded ($failures | length) failing phase\(s\)(ansi reset) — see FINDING lines above; nothing was edited to force green"
        for f in $failures { print $"  ($f.phase): ($f.error)" }
        error make {msg: $"live smoke: ($failures | length) phase\(s\) failed \(($failures | get phase | str join ', ')\)"}
    }
}

