#!/usr/bin/env nu
# live-smoke — the live-Pi run of the worker bus, made repeatable.
#
#   nu tests/pi-worker/live-smoke.nu
#   nu tests/pi-worker/live-smoke.nu --keep --timeout 600
#
# NOT part of `run-tests.nu`, and not a merge gate. That suite proves the
# protocol on any machine, every time, with a stub in place of Pi. This script
# is the other half the suite's own header admits it cannot be: two real Pi
# agents, in real tmux windows, in real worktrees of this repo, spending real
# tokens. Run it when the bus itself changes — spawn, delivery, resume, accept,
# teardown — and read the suite for everything else.
#
# It costs money and a few minutes per run. Nothing else here does, which is
# why it is opt-in and why it says so this loudly.
#
# The regressions it exists to catch, all three found by running exactly this
# flow by hand:
#
#   dotfiles-nig0  a result that `resume` sent back was still delivered by
#                  `wait`, indistinguishable from a fresh report
#   dotfiles-ycvl  and still counted as unacked mail by `status`
#   dotfiles-pwxf  `accept` removed the worktree, then declined to delete the
#                  branch — leaving the worker unacceptable AND unreleasable
#
# The worker instructions are part of the fixture, not decoration. The totals
# row in the line-count task is worded the way it is because "sort the table by
# line count descending, and add a TOTAL row" is ambiguous: the totals row is
# in the table and its number is the largest one, so sorting it to the top is a
# correct reading of that sentence, and a worker did exactly that. What removes
# the ambiguity is naming the sort domain (the FILE rows), excluding the total
# from it, and fixing when it is appended (after sorting) — all three, because
# each was separately guessable.

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

# The same, for a comparison — and it PRINTS BOTH SIDES when it fails.
#
# Written after a run where `check ($rows == $expected) "counts match git"`
# failed and said only that. Teardown then removed the worktree the file was
# in, so the one artifact that could have explained it was gone: a live check
# that reports a mismatch without reporting the mismatch costs a whole run.
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

# ------------------------------------------------------------------- the CLI
#
# Driven as an operator drives it, through the installed `pi-worker` rather
# than by importing the module. The acceptance suite learned this the hard way
# (dotfiles-87bt): a case that called the module directly proved a headline
# claim against a path no caller could take.

def cli-raw [args: list<string>, socket: string]: nothing -> record {
    let full = (if ($socket | is-empty) { $args } else { $args ++ ["--socket" $socket] })
    do { ^pi-worker ...$full } | complete
}

def cli [args: list<string>, socket: string = ""]: nothing -> any {
    let out = (cli-raw $args $socket)
    if $out.exit_code != 0 {
        error make {msg: $"pi-worker ($args | str join ' ') failed: ($out.stderr | str trim)"}
    }
    let text = ($out.stdout | str trim)
    if ($text | is-empty) { return null }
    $text | from json
}

# A verb expected to REFUSE. The reason is the point: a refusal that does not
# say why is the failure mode most of this bus's comments are about.
def cli-refuses [args: list<string>, expect: string, socket: string = ""]: nothing -> string {
    let out = (cli-raw $args $socket)
    if $out.exit_code == 0 {
        error make {msg: $"pi-worker ($args | str join ' ') was expected to refuse, but succeeded: ($out.stdout | str trim)"}
    }
    let reason = ($out.stderr | str trim)
    if not ($reason | str lowercase | str contains ($expect | str lowercase)) {
        error make {msg: $"refusal must mention '($expect)', got: ($reason)"}
    }
    # The message, not nushell's rendering of it. `Error: nu::shell::error` is
    # the first line of every one of these and says nothing about the refusal;
    # the text lives on the `x` line under it.
    let spoken = ($reason | lines | where {|l| ($l | str trim | str starts-with "x ") })
    if ($spoken | is-empty) { $reason } else { $spoken | first | str trim | str substring 2.. | str trim }
}

# ------------------------------------------------------------ table reading
#
# The workers write markdown, so the checks read markdown. Bold, backticks and
# the separator row are noise here: what is being verified is which rows there
# are, in what order, and what numbers they carry.

def table-rows [file: string]: nothing -> list<list<string>> {
    open --raw $file
    | lines
    | where {|l| ($l | str trim | str starts-with "|") }
    | each {|l|
        $l | str trim | str trim --char "|" | split row "|"
        | each {|c| $c | str trim | str replace --all "*" "" | str replace --all "`" "" | str trim }
    }
    | where {|r|
        # Drop the |---|---:| separator, whatever alignment colons it carries.
        not ($r | all {|c| ($c | str replace --all "-" "" | str replace --all ":" "" | is-empty) })
    }
}

def as-int [cell: string]: nothing -> int {
    let digits = ($cell | str replace --all --regex '[^0-9]' "")
    if ($digits | is-empty) { -1 } else { $digits | into int }
}

# The check the corrected wording exists for: a totals row that is LAST, whose
# number is the sum of the rows above it, and rows that are ordered.
def check-ranked-table-with-total [file: string, label: string] {
    let rows = (table-rows $file)
    check (($rows | length) >= 3) $"($label): a header, at least one row and a total"
    let body = ($rows | skip 1)
    let last = ($body | last)
    check (($last | first | str lowercase) == "total") $"($label): the totals row is the final row, not the first"

    let ranked = ($body | drop 1)
    let counts = ($ranked | each {|r| as-int ($r | last) })
    check ($counts | all {|n| $n >= 0 }) $"($label): every ranked row carries a number"
    check (($counts | sort --reverse) == $counts) $"($label): ranked rows are in descending order"
    check ((as-int ($last | last)) == ($counts | math sum)) $"($label): the total is the sum of the rows above it"
}

# ------------------------------------------------------------------- fixture
#
# Both tasks are computed from ONE corpus — the tracked files matching `--glob`
# — and both are checked against git rather than against the worker's own
# account of itself. A smoke test that believed the summary would pass whatever
# a worker wrote in it.
#
# One corpus, small by default, because every row here is tokens: a task big
# enough to be real and small enough that a failed run is cheap to repeat.

def glob-files [repo: string, pattern: string]: nothing -> list<string> {
    ^git -C $repo ls-files -- $pattern | lines | where {|f| ($f | is-not-empty) }
}

# Top-level directory of each match, with how many matches it holds, ranked the
# way the second round asks the worker to rank it: count descending, ties
# alphabetical.
#
# Ranked on a negated count in ONE ascending multi-column sort, not by sorting
# alphabetically and then reversing on the count. `sort-by files --reverse`
# reverses the ties along with everything else, so this fixture expected
# `claude` before `classicshell` and the worker — correctly, since `s` sorts
# before `u` — wrote them the other way round. The check failed against the
# worker for two runs, and the worker was right both times.
def dirs-with-matches [corpus: list<string>]: nothing -> table<dir: string, files: int> {
    $corpus
    | where {|f| ($f | str contains "/") }
    | each {|f| $f | split row "/" | first }
    | uniq --count
    | rename dir files
    | insert rank {|r| 0 - $r.files }
    | sort-by rank dir
    | reject rank
}

def line-count [repo: string, file: string]: nothing -> int {
    open --raw ([$repo $file] | path join) | lines | length
}

# ------------------------------------------------------------------ teardown
#
# Only what THIS run spawned, addressed by the ids its own spawns reported —
# never a name, never a pattern over the window list. A worker's window id and
# worktree path are recorded at spawn precisely so teardown can be specific,
# and `--force` is defensible only because of that: the tree being removed is
# one this script created minutes ago, and a round that failed mid-edit leaves
# it dirty, which is exactly when teardown must still work.
def reap [workers: list<record>, run: string, repo: string, keepsake: string, socket: string] {
    print ""
    step "teardown"
    if ($keepsake | is-not-empty) {
        do { ^git -C $repo branch -D $keepsake } | complete | ignore
    }
    for w in $workers {
        let tmux_args = (if ($socket | is-empty) { [] } else { ["-L" $socket] })
        do { ^tmux ...$tmux_args kill-window -t $w.window_id } | complete | ignore
        if ($w.cwd | path exists) {
            do { ^git -C $repo worktree remove --force $w.cwd } | complete | ignore
        }
        do { ^git -C $repo branch -D $w.branch } | complete | ignore
        cli-raw ["stop" $w.uid "--run" $run] $socket | ignore
        cli-raw ["rm" "--run" $run "--uid" $w.uid] $socket | ignore
    }
    let left = (cli ["workers" "--run" $run] $socket)
    if ($left | is-empty) {
        print $"  (ansi green)ok(ansi reset)   run ($run) released, no worktrees or branches left"
    } else {
        print $"  (ansi yellow)note(ansi reset) ($left | length) worker\(s\) still on the bus under ($run): ($left | get uid | str join ', ')"
    }
}

# ---------------------------------------------------------------------- main

def main [
    --stage: string = "work"           # a registered stage with isolation=worktree, payload=instructions
    --glob: string = "*/scripts/*.nu"  # git pathspec for the corpus both tasks describe
    --timeout: int = 300         # seconds to block on any one report
    --project: string = ""       # tmux session group; derived from the current session when empty
    --socket: string = ""        # alternate tmux socket
    --keep                       # leave the workers, trees and branches in place for inspection
] {
    print $"(ansi cyan)pi-worker live smoke(ansi reset) — two real Pi workers, real tokens"
    print ""

    step "preflight"
    for dep in ["pi-worker" "pi" "tmux" "git"] {
        check ((which $dep | length) > 0) $"($dep) on PATH"
    }
    let repo = (do { ^git rev-parse --show-toplevel } | complete)
    check ($repo.exit_code == 0) "run from inside a git repository"
    let repo = ($repo.stdout | str trim)
    check (($env | get -o TMUX | default "" | is-not-empty) or ($project | is-not-empty)) "inside tmux, or --project given"

    # The stage gate is the consumer's, so the script asks rather than assumes:
    # a stage placed in the main worktree would put both workers in the
    # operator's own tree, and a ticket-payload stage cannot be sent prose.
    let stages_path = ($env | get -o PI_WORKER_STAGES | default (
        [($env | get -o XDG_CONFIG_HOME | default ([$env.HOME ".config"] | path join)) "pi-workers" "stages.json"] | path join
    ))
    check ($stages_path | path exists) $"a stage registry at ($stages_path)"
    let registered = (open --raw $stages_path | from json | get stages | where name == $stage)
    check ($registered | is-not-empty) $"stage '($stage)' is registered"
    let declared = ($registered | first)
    check ($declared.isolation == "worktree") $"stage '($stage)' is isolated, so neither worker touches the operator's tree"
    check ($declared.payload == "instructions") $"stage '($stage)' takes prose"

    let corpus = (glob-files $repo $glob)
    let dirs = (dirs-with-matches $corpus)
    check (($corpus | length) >= 2) $"($glob) matches at least two tracked files — pass --glob otherwise"
    check (($dirs | length) >= 2) $"($glob) spans at least two top-level directories"
    print $"  (ansi grey)($corpus | length) files matching ($glob), across ($dirs | length) top-level dirs(ansi reset)"

    let tag = (random chars --length 4 | str lowercase)
    mut workers = []
    mut keepsake = ""
    mut run = ""

    let outcome = (try {
        # ------------------------------------------------------------ spawn
        print ""
        step "spawn two workers"
        let project_args = (if ($project | is-empty) { [] } else { ["--project" $project] })
        let a = (cli (["spawn" "--role" "impl" "--subject" $"smoke-dirs-($tag)" "--skill" $stage "--repo" $repo] ++ $project_args) $socket)
        $run = $a.run
        let b = (cli (["spawn" "--run" $run "--role" "impl" "--subject" $"smoke-lines-($tag)" "--skill" $stage "--repo" $repo] ++ $project_args) $socket)
        $workers = [$a $b]
        check ($a.liveness == "live") $"($a.uid) is live in ($a.window)"
        check ($b.liveness == "live") $"($b.uid) is live in ($b.window)"
        check ($a.cwd != $b.cwd) "each worker got its own worktree"
        print $"  (ansi grey)run ($run): ($a.uid) → ($a.branch), ($b.uid) → ($b.branch)(ansi reset)"

        # ------------------------------------------------------------- work
        print ""
        step "send one task each"
        cli ["send" $a.uid "--run" $run "--stage" $stage "--instructions" $"In your worktree, create smoke/dirs.md. The corpus is exactly the files listed by `git ls-files -- '($glob)'` — enumerate them with that command, not with a shell glob, because git pathspecs and shell globs disagree about whether `*` crosses a `/`. Write one line per top-level directory holding at least one corpus file, sorted alphabetically, and a final line reading `total <n>`. Commit it. Then report your result with a non-empty validation field naming how you verified the list."] $socket | ignore
        # The wording that took three tries to get right — see the header.
        cli ["send" $b.uid "--run" $run "--stage" $stage "--instructions" $"In your worktree, create smoke/lines.md. The corpus is exactly the files listed by `git ls-files -- '($glob)'` — enumerate them with that command, not with a shell glob, because git pathspecs and shell globs disagree about whether `*` crosses a `/`. Write a markdown table of every corpus file with its line count. Sort the FILE rows by line count descending. The totals row is not one of the ranked rows: append it after sorting, as the final row of the table, labelled TOTAL. Commit it. Then report your result with a non-empty validation field naming the command you used to count."] $socket | ignore

        for w in [$a $b] {
            let got = (cli ["wait" "--run" $run "--uid" $w.uid "--block" "--timeout" ($timeout | into string)] $socket)
            check ($got != null) $"($w.uid) reported within ($timeout)s"
            check ($got.payload.status == "complete") $"($w.uid) reported complete"
            check (($got.payload.validation | default "" | is-not-empty)) $"($w.uid) carried a verdict, which the stage gate requires"
        }

        # Neither is acked yet, on purpose: the delivery checks below need one
        # worker holding real mail while the other's is superseded.
        check-ranked-table-with-total ([$b.cwd "smoke/lines.md"] | path join) "lines.md"
        let reported = (table-rows ([$b.cwd "smoke/lines.md"] | path join) | skip 1 | drop 1)
        let expected = ($corpus | each {|f| {file: $f, lines: (line-count $repo $f)} } | sort-by lines --reverse)
        check-eq ($reported | length) ($expected | length) $"lines.md lists all ($expected | length) files"
        check-eq ($reported | each {|r| as-int ($r | last) }) ($expected | get lines) "lines.md line counts match git + wc"
        let dirs_file = ([$a.cwd "smoke/dirs.md"] | path join)
        check ($dirs_file | path exists) "dirs.md exists"
        let named = ($dirs | get dir)
        let listed = (open --raw $dirs_file | lines | each {|l| $l | str trim } | where {|l| $l in $named })
        check-eq ($listed | sort) ($named | sort) $"dirs.md names all ($named | length) directories the corpus spans"

        # -------------------------------------------------- send-back (nig0)
        print ""
        step "send one worker back for another round"
        let sent_back = (cli ["resume" $a.uid "--run" $run "--feedback" $"Improvement round: make smoke/dirs.md a markdown table with two columns, the directory and how many corpus files it holds \(same corpus as before: `git ls-files -- '($glob)'`\). Sort the DIRECTORY rows by that count descending, ties alphabetical. The totals row is not one of the ranked rows: append it after sorting, as the final row, labelled TOTAL. Commit and report again with validation."] $socket)
        check ($sent_back.state == "running") $"($a.uid) is running again"

        # dotfiles-nig0: this returned the rejected `complete` envelope.
        check ((cli ["wait" "--run" $run "--uid" $a.uid] $socket) == null) "the result that was sent back is no longer delivered"
        # dotfiles-ycvl: and it was still counted as mail.
        check ((cli ["status" $a.uid "--run" $run] $socket | get unacked) == 0) "nor counted as unacknowledged"
        # The other half: skipping one envelope must not skip the run.
        let sibling = (cli ["wait" "--run" $run] $socket)
        check ($sibling != null and $sibling.uid == $b.uid) $"the run-wide wait still hands over ($b.uid)'s report"

        # A message sent to a worker that is already working. Whether it is
        # folded into the round in flight or handled as a round of its own
        # depends on a race this script cannot win — these workers finish in
        # well under a minute — so the instruction says what to do in either
        # case and the check accepts either. What is being tested is that a
        # `send` to a reopened worker is DELIVERED and acted on; asserting the
        # commit it lands in would be asserting the timing.
        step "add an instruction while that round is in flight"
        cli ["send" $a.uid "--run" $run "--stage" $stage "--instructions" "Additional instruction: give smoke/dirs.md a first line reading exactly `# Top-level directories`. Fold it into the round you are doing; if you have already reported that round, make the change now, commit, and report again."] $socket | ignore

        let second = (cli ["wait" "--run" $run "--uid" $a.uid "--block" "--timeout" ($timeout | into string)] $socket)
        check ($second != null and $second.sequence == 2) "what arrives is the second round, not the first"
        check ($second.payload.status == "complete") $"($a.uid) completed the second round"
        check-ranked-table-with-total ([$a.cwd "smoke/dirs.md"] | path join) "dirs.md"
        let dir_rows = (table-rows ([$a.cwd "smoke/dirs.md"] | path join) | skip 1 | drop 1)
        check-eq ($dir_rows | each {|r| {dir: ($r | first), files: (as-int ($r | last))} }) $dirs "dirs.md counts and order match git"

        let dirs_md = ([$a.cwd "smoke/dirs.md"] | path join)
        let wanted = "# Top-level directories"
        mut latest = $second.sequence
        if ((open --raw $dirs_md | lines | first) != $wanted) {
            step "that round had already closed — the instruction becomes a round of its own"
            let third = (cli ["wait" "--run" $run "--uid" $a.uid "--block" "--timeout" ($timeout | into string)] $socket)
            check ($third != null) $"($a.uid) reported again within ($timeout)s"
            check ($third.sequence == ($second.sequence + 1)) "as the next sequence on the same worker"
            $latest = $third.sequence
        }
        check-eq (open --raw $dirs_md | lines | first) $wanted "the instruction sent mid-round was acted on"
        # Still the same table underneath: an extra instruction is not licence
        # to rewrite what the round already got right.
        check-ranked-table-with-total $dirs_md "dirs.md"
        check-eq (table-rows $dirs_md | skip 1 | drop 1 | each {|r| {dir: ($r | first), files: (as-int ($r | last))} }) $dirs "dirs.md still matches git"

        # ------------------------------------------------------------- ack
        print ""
        step "acknowledge both reports"
        # A's sequence is whatever its last round turned out to be, not a
        # literal: the extra instruction may have added one.
        for pair in [[$a.uid, $latest], [$b.uid, 1]] {
            let acked = (cli ["ack" "--run" $run "--uid" ($pair | first) "--sequence" ($pair | last | into string)] $socket)
            check $acked.released $"($pair | first) released its window on ack"
        }
        check ((cli ["wait" "--run" $run] $socket) == null) "the run's mailbox is drained"

        # --------------------------------------------------- accept (pwxf)
        print ""
        step "accept a worker whose commits are on no other ref"
        let refusal = (cli-refuses ["accept" $a.uid "--run" $run "--repo" $repo] "no other ref" $socket)
        check ($a.cwd | path exists) "the refusal left the worktree standing"
        check ((^git -C $repo branch --list $a.branch | str trim | is-not-empty)) "and its branch"
        check ((cli ["status" $a.uid "--run" $run] $socket | get state) == "complete") "and the state that can still be accepted"

        step "preserve the work, then accept again"
        $keepsake = $"smoke-keepsake-($tag)"
        ^git -C $repo branch $keepsake $a.branch
        let accepted = (cli ["accept" $a.uid "--run" $run "--repo" $repo] $socket)
        check ($accepted.state == "accepted") "the retry lands once the work is preserved"
        check (not ($a.cwd | path exists)) "the worktree is reclaimed"
        check ((^git -C $repo branch --list $a.branch | str trim | is-empty)) "the worker's branch is deleted"
        check ((^git -C $repo branch --list $keepsake | str trim | is-not-empty)) "the ref that preserves the work is left alone"
        check ((cli ["accept" $a.uid "--run" $run "--repo" $repo] $socket | get changed) == false) "accepting twice is a no-op"
        check ((cli ["rm" "--run" $run "--uid" $a.uid] $socket | get removed)) "and the address can be released"

        print ""
        print $"(ansi green)live smoke passed(ansi reset) — run ($run), ($workers | length) workers"
        print $"  (ansi grey)refusal seen: ($refusal | lines | first)(ansi reset)"
        null
    } catch {|e| $e })

    if $keep {
        print ""
        print $"(ansi yellow)--keep:(ansi reset) leaving run ($run) in place. Teardown by hand:"
        for w in $workers {
            print $"  pi-worker stop ($w.uid) --run ($run); git -C ($repo) worktree remove --force ($w.cwd); git -C ($repo) branch -D ($w.branch); pi-worker rm --run ($run) --uid ($w.uid)"
        }
        if ($keepsake | is-not-empty) { print $"  git -C ($repo) branch -D ($keepsake)" }
    } else if ($run | is-not-empty) {
        reap $workers $run $repo $keepsake $socket
    }

    if $outcome != null {
        print ""
        error make {msg: $"live smoke failed: ($outcome.msg)"}
    }
}
