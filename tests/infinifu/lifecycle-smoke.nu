#!/usr/bin/env nu
# Pipeline smoke for sp037 (infinifu-lifecycle-drives-pi-worker).
#
# Mints a FRESH bd task per invocation whose work is to write a fixed-header
# file to docs/notes/lab/smoke-<ts>.md, then drives it through the full
# lifecycle — dispatch, work-do, work-audit, work-merge — naming each step by
# the operation names in runtime-adapter.md's `## operation binding` table
# (dispatch, send work, await, reject/resume, accept and clean, tear down,
# inspect) rather than hardcoding either runtime's tool names here. --runtime
# picks the column: this file is the one driver that walks both.
#
# The five-assertion checker (`check-smoke-run`, below) is a PURE function
# over an already-gathered state record: no git, no bd, no filesystem calls
# inside it. That is what lets smoke-cases.nu exercise all five assertions,
# the report-every-failure behavior, and the adversarial fixtures (the
# dotfiles-41fr wrong-branch shape, and a bd-other.0 branch that matches the
# bd-branch shape but not THIS task's own id) without spawning a single
# worker. A real run costs model tokens — that live run is sp037 Task 6; this
# file is import-only for tests until then:
#
#   use tests/infinifu/lifecycle-smoke.nu check-smoke-run
#
# Live usage (Task 6):
#   nu tests/infinifu/lifecycle-smoke.nu --runtime claude
#   nu tests/infinifu/lifecycle-smoke.nu --runtime pi
#
# Exits 0 when all five assertions pass, 1 otherwise, printing every failed
# assertion by name — never just the first, because a half-finished run is
# the normal case while this pipeline is new.
#
# Nothing here writes to claude/marketplace/plugins/pi-workers/ — the smoke
# calls the pi-worker CLI as a black box (adr0031: the transport interprets
# nothing) and never edits its source.

# ------------------------------------------------------------- the checker

# Expected branch prefix for a bd task id. A branch is only correct if it
# starts with the TASK'S OWN id — dotfiles-41fr landed on the literal branch
# `wk-timestamp-file.0` instead of its bd branch, and a check that only
# verified "looks like a bd-*.N branch" would have waved that through, and so
# would `bd-other.0` for a task that isn't `other`.
export def expected-branch-prefix [task_id: string] {
    $"bd-($task_id)."
}

# Expected smoke-file path for a given minted timestamp. Kept as its own
# function so the driver and the checker agree on the naming scheme, and so a
# stale file from an earlier run (a different timestamp) can never satisfy a
# later run: the checker only ever looks at ITS OWN run's exact path, never a
# glob over docs/notes/lab/smoke-*.md.
export def smoke-file-path [ts: string] {
    $"docs/notes/lab/smoke-($ts).md"
}

# The five assertions, as one pure function over already-gathered state.
#
# `state` fields (all gathered by the driver's IO — never touched in here):
#   task_id            string           — the bd task id minted for this run
#   observed_branch    string           — branch the work actually landed on
#   worktree_exists    bool             — per-task worktree dir still present?
#   branch_exists      bool             — per-task branch ref still present?
#   smoke_ts           string           — this run's own minted timestamp
#   expected_header    string           — fixed header line the file must carry
#   smoke_file_content string | nothing — content at THIS run's expected smoke
#                                          path on base, or null if that exact
#                                          file does not exist (a stale file
#                                          living at a DIFFERENT path is not
#                                          this field — see smoke-file-path)
#   task_status        string           — bd task status observed post-run
#   task_notes         string           — bd task notes observed post-run
#   bus_result         record           — the typed result envelope read off
#                                          the bus, or a partial/prose-shaped
#                                          record for a protocol violation
#
# Returns {ok: bool, failures: list<record<name: string, detail: string>>} —
# every failed assertion is reported, never just the first.
export def check-smoke-run [state: record] {
    mut failures = []

    # 1. branch was bd-<id>.<N> — bound to the task's OWN id, not any bd-*.N
    let prefix = (expected-branch-prefix $state.task_id)
    if not ($state.observed_branch | str starts-with $prefix) {
        $failures = ($failures | append {
            name: "branch"
            detail: $"expected a branch starting with '($prefix)', got '($state.observed_branch)'"
        })
    }

    # 2. the smoke file landed on base with the header — THIS run's own path,
    #    never a glob, so a leftover file from a previous run cannot satisfy it.
    let content = ($state | get -o smoke_file_content)
    let path = (smoke-file-path $state.smoke_ts)
    if ($content == null) {
        $failures = ($failures | append {
            name: "smoke-file"
            detail: $"expected ($path) to exist on base with header '($state.expected_header)', but it is missing"
        })
    } else if not ($content | str contains $state.expected_header) {
        $failures = ($failures | append {
            name: "smoke-file"
            detail: $"expected header '($state.expected_header)' in ($path), got: ($content)"
        })
    }

    # 3. the bd task is closed and carries audit evidence in notes
    let notes_have_evidence = ($state.task_notes | str lowercase | str contains "audit")
    if ($state.task_status != "closed") or (not $notes_have_evidence) {
        $failures = ($failures | append {
            name: "task-closed"
            detail: $"expected status 'closed' with audit evidence in notes, got status '($state.task_status)', notes: '($state.task_notes)'"
        })
    }

    # 4. the worktree and branch are gone
    if $state.worktree_exists or $state.branch_exists {
        $failures = ($failures | append {
            name: "cleanup"
            detail: $"expected worktree and branch removed, got worktree_exists=($state.worktree_exists) branch_exists=($state.branch_exists)"
        })
    }

    # 5. the bus carries a typed result (status, summary, validation —
    #    adr0027) rather than prose. A record missing any of the three named
    #    fields, or carrying only a free-text summary, fails this.
    let cols = ($state.bus_result | columns)
    let has_status = (
        ("status" in $cols)
        and (($state.bus_result.status | describe) == "string")
        and (($state.bus_result.status | str length) > 0)
    )
    let has_summary = (
        ("summary" in $cols)
        and (($state.bus_result.summary | str length) > 0)
    )
    let has_validation = (
        ("validation" in $cols)
        and (($state.bus_result.validation | str length) > 0)
    )
    if not ($has_status and $has_summary and $has_validation) {
        $failures = ($failures | append {
            name: "typed-result"
            detail: $"expected a typed result with status, summary and validation fields \(adr0027\), got columns: ($cols)"
        })
    }

    {ok: ($failures | is-empty), failures: $failures}
}

# --------------------------------------------------------------- the driver
#
# Real IO lives only below this line. None of it is exercised by
# smoke-cases.nu — that is the point of pulling the checker out above.

# One fixed header, checked verbatim by assertion 2. Distinctive enough that
# it can't collide with unrelated files in docs/notes/lab/.
const SMOKE_HEADER = "# infinifu lifecycle smoke"

def mint-timestamp [] {
    date now | format date "%Y%m%d%H%M%S%f"
}

def base-dir [] {
    ^git rev-parse --show-toplevel | str trim
}

# Mint a fresh bd task whose work is to write the smoke file, per success
# criterion 1. Returns the new task id.
def mint-smoke-task [ts: string] {
    let path = (smoke-file-path $ts)
    let design = $"Write ($path) with a first line of exactly:\n\n($SMOKE_HEADER)\n\nThen commit it on your task branch as usual. This task exists only to drive tests/infinifu/lifecycle-smoke.nu \(sp037 Task 5/6\) and has no other purpose."
    let out = (^bd create $"sp037 lifecycle smoke ($ts)" --type task --design $design | complete)
    if $out.exit_code != 0 {
        error make {msg: $"bd create failed for the smoke task: ($out.stderr)"}
    }
    # `bd create` prints the new id; the exact format is owned by bd, so pull
    # the first bd-id-shaped token out of stdout rather than assuming a
    # column position.
    let id = ($out.stdout | str trim | parse -r '([a-zA-Z0-9_-]+-[a-zA-Z0-9]+)' | get -o 0.capture0)
    if $id == null {
        error make {msg: $"could not parse a bd task id out of: ($out.stdout)"}
    }
    $id
}

# Drive one lifecycle operation by its binding-table NAME, dispatching to the
# runtime-specific command only here — see runtime-adapter.md's
# `## operation binding`. Adding a runtime is adding a `when` arm, never a
# rewrite of the steps below.
def drive-op [op: string, runtime: string, ctx: record] {
    match $runtime {
        "pi" => (drive-op-pi $op $ctx)
        "claude" => (drive-op-claude $op $ctx)
        _ => (error make {msg: $"unsupported-runtime: lifecycle-smoke has no binding for '($runtime)' at operation '($op)'"})
    }
}

def drive-op-pi [op: string, ctx: record] {
    match $op {
        "dispatch" => (
            ^pi-worker spawn --role $ctx.role --subject $ctx.task_id --skill $ctx.skill --isolation worktree
            | complete
        )
        "send-work" => (^pi-worker send --as $ctx.run --to $ctx.worker --content $ctx.content | complete)
        "await" => (^pi-worker wait --as $ctx.run --block --timeout $ctx.timeout | complete)
        "reject-resume" => (^pi-worker resume $ctx.worker --feedback $ctx.feedback | complete)
        "accept-clean" => (^pi-worker accept $ctx.worker --repo (base-dir) | complete)
        "tear-down" => (^pi-worker stop $ctx.worker | complete)
        "inspect" => (^pi-worker inspect $ctx.worker | complete)
        _ => (error make {msg: $"unknown operation '($op)'"})
    }
}

# The Claude native surface has no shell-callable form for `Agent` / `Task` —
# those are in-session tool calls, not CLI verbs. A script run OUTSIDE a
# Claude Code session cannot perform "dispatch" on this column at all, so the
# Claude-runtime live run (Task 6) is driven from inside a Claude Code session
# that calls this file's `check-smoke-run` after doing dispatch / send work /
# await / reject-resume / accept-clean / tear-down / inspect itself via its
# native tools, then feeds the gathered state back in. This function exists
# so the shape is documented and so an accidental CLI invocation fails loudly
# instead of silently no-op'ing.
def drive-op-claude [op: string, ctx: record] {
    error make {msg: $"unsupported-runtime: 'claude' has no CLI-callable '($op)' — drive this operation from inside a Claude Code session via its native Agent/SendMessage/TaskStop/ListAgents tools per runtime-adapter.md, then call check-smoke-run with the gathered state"}
}

# Gather post-run state for the checker. Real IO; not exercised by tests.
def gather-state [task_id: string, smoke_ts: string, branch: string, worktree: string, bus_result: record] {
    let base = (base-dir)
    let path = ([$base (smoke-file-path $smoke_ts)] | path join)
    let content = (if ($path | path exists) { open $path } else { null })
    let notes = (^bd show $task_id | complete | get stdout)
    let status = (if ($notes | str lowercase | str contains "closed") { "closed" } else { "in_progress" })
    {
        task_id: $task_id
        observed_branch: $branch
        worktree_exists: ($worktree | path exists)
        branch_exists: (
            (^git -C $base branch --list $branch | complete | get stdout | str trim | str length) > 0
        )
        smoke_ts: $smoke_ts
        expected_header: $SMOKE_HEADER
        smoke_file_content: $content
        task_status: $status
        task_notes: $notes
        bus_result: $bus_result
    }
}

# One stage of the pipeline: dispatch a worker with the given role/skill,
# send it its work content, and await its completion (blocking, bounded by
# --timeout). Returns the worker uid and its parsed typed result, or exits
# the whole script with a named BLOCKED reason — a worker that never reports
# must time out with itself named, never hang.
def run-stage [runtime: string, role: string, skill: string, content: string, timeout: int] {
    let spawned = (drive-op "dispatch" $runtime {role: $role, task_id: $content, skill: $skill})
    if $spawned.exit_code != 0 {
        print $"BLOCKED at dispatch \(($role)\): ($spawned.stderr)"
        exit 1
    }
    let reply = ($spawned.stdout | from json)
    let run = $reply.run
    let worker = $reply.uid

    let sent = (drive-op "send-work" $runtime {run: $run, worker: $worker, content: $content})
    if $sent.exit_code != 0 {
        print $"BLOCKED at send-work to ($worker): ($sent.stderr)"
        exit 1
    }

    let awaited = (drive-op "await" $runtime {run: $run, timeout: $timeout})
    if $awaited.exit_code != 0 {
        print $"BLOCKED: worker ($worker) did not report within ($timeout)s \(await timed out\)"
        exit 1
    }

    {worker: $worker, result: ($awaited.stdout | from json)}
}

# Entry point for the live run (sp037 Task 6). `--runtime` selects the
# operation-binding column; the same invocation shape and the same checker
# cover both. The Claude column has no shell-callable dispatch (see
# drive-op-claude) — driving that column means running these same steps from
# inside a Claude Code session, then calling check-smoke-run directly.
def main [--runtime: string = "claude", --timeout: int = 60] {
    if not ($runtime in ["claude" "pi"]) {
        error make {msg: $"unsupported-runtime: '($runtime)' — expected 'claude' or 'pi'"}
    }
    if $runtime == "claude" {
        error make {msg: "unsupported-runtime: 'claude' has no CLI-callable dispatch (Agent/Task are in-session tool calls, not shell verbs) — drive dispatch / send-work / await / reject-resume / accept-clean / tear-down from inside a Claude Code session per runtime-adapter.md, gather state the same way gather-state does here, and call check-smoke-run directly"}
    }

    let ts = (mint-timestamp)
    let task_id = (mint-smoke-task $ts)
    print $"minted ($task_id) for smoke run ($ts) on runtime '($runtime)'"

    # implementer: dispatch -> send work -> await, per the binding table.
    let impl = (run-stage $runtime "implementer" "infinifu:work-do" $task_id $timeout)
    print $"implementer ($impl.worker) reported: ($impl.result | to json -r)"

    # reviewer: dispatch -> send work -> await. work-audit owns the
    # in_progress -> closed transition and, on approval, triggers work-merge
    # itself — so this second stage is what actually lands the branch,
    # closes the task with audit evidence, and sweeps the worktree.
    let review = (run-stage $runtime "reviewer" "infinifu:work-audit" $task_id $timeout)
    print $"reviewer ($review.worker) reported: ($review.result | to json -r)"

    # accept-clean + tear-down: sweep whatever this run spawned, and nothing
    # else (adr0017) — the reviewer's own worktree, not any other agent's.
    drive-op "accept-clean" $runtime {worker: $review.worker} | ignore
    drive-op "tear-down" $runtime {worker: $impl.worker} | ignore
    drive-op "tear-down" $runtime {worker: $review.worker} | ignore

    let branch = ($impl.result | get -o branch | default "")
    let worktree = ($impl.result | get -o worktree | default "")
    let state = (gather-state $task_id $ts $branch $worktree $review.result)

    let outcome = (check-smoke-run $state)
    if $outcome.ok {
        print $"PASS — all five assertions held for ($task_id) on '($runtime)'"
        exit 0
    } else {
        print $"FAIL — ($outcome.failures | length) of 5 assertions failed for ($task_id) on '($runtime)':"
        for f in $outcome.failures {
            print $"  - ($f.name): ($f.detail)"
        }
        exit 1
    }
}
