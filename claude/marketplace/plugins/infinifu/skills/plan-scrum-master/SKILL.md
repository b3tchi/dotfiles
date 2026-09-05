---
name: plan-scrum-master
description: >-
  Use when running or orchestrating multi-agent work from a bd task queue or epic. On Claude's native branch, dispatches implementer and reviewer agents in isolated worktrees, retries failures, respects concurrency limits, and supports auto, waves, blockers-only, and worker-model choices. Under Pi, fails clearly or defers multi-worker dispatch unless an explicit Pi adapter is installed; use plan-supervised for sequential Pi execution. Trigger on "dispatch agents", "run the pipeline", "execute the epic", "process bd ready", "start scrum master", or `/plan-dispatch-fnf`. Pick plan-supervised for human-reviewed batches. Do not use for task creation, specs, brainstorming, or one solo task.

---

# Scrum Master — Pipeline Orchestrator

## Overview

Orchestrate bd-driven development by reading the ready queue, applying the runtime adapter gate, and tracking pipeline progress. Claude's native branch dispatches implementer agents and relays their reports to reviewer agents; Pi reports unsupported or defers multi-worker dispatch until a Pi adapter exists.

**Core principle:** You are a task dispatcher that stays on main. Your domain is bd. You never touch code, git, worktrees, or files. On the Claude native branch, you read the board, dispatch agents (no `isolation: "worktree"` — implementers create their own worktree at `bd-<id>.<N>` so dir name matches branch name), relay information, and track progress. On the Pi branch, you do not claim Claude agent dispatch occurred unless an explicit Pi adapter supplies equivalent semantics. Reviewers verify and per-task land via work-audit → work-merge.

**Announce at start:** "I'm using the plan-scrum-master skill to orchestrate the pipeline."

## Execution Model

### Runtime adapter gate

Follow the shared runtime-selection contract in
`../meta-patterns/runtime-adapter.md` before dispatching work.

#### Claude native branch

When Claude's native agent surface is available, the main Claude session is the
scrum-master — the user invokes the skill directly (`/plan-dispatch-fnf` or
equivalent) and talks to the orchestrator as themselves. Workers (implementers
+ reviewers) are dispatched as **named** background subagents via the `Agent`
tool. Every dispatch passes `name` — `impl-<bd-id>` for implementers,
`rev-<bd-id>` for reviewers — and that name is the agent's address for
`SendMessage`, `ListAgents`, and `TaskStop`. Subagents always run in the
background; there is no `run_in_background` parameter on the `Agent` tool (nor
on `SendMessage`) — do not pass one. Each implementer creates its own worktree
at `bd-<id>.<N>` as part of work-do Step 2 (the previous
`isolation: "worktree"` shortcut was dropped because the auto-generated dir name
was opaque and broke the dir-to-task mapping). Main Claude reacts to completion
notifications; it does not poll or sleep.

This branch preserves named background subagent dispatch, completion
notifications, `SendMessage({to: "impl-<bd-id>", message: "..."})` resume
semantics, and `TaskStop({task_id: "impl-<bd-id>"})` stop semantics. In other
words, Claude workers are named background subagents via the `Agent` tool.

#### Pi branch (`AI_AGENT=pi`)

Pi must not dispatch Claude `Agent` subagents, call `SendMessage`, call
`ListAgents`, call `TaskStop`, infer worker state from tmux panes, or claim a
Claude background worker was launched. If no explicit Pi multi-worker adapter
is installed, this skill's visible multi-worker pipeline is unsupported until
[[sp028]] or a later Pi adapter supplies it. For one-task or human-supervised
sequential lifecycle execution under Pi, use `plan-supervised`'s sequential Pi
branch: run one `work-do` / `work-audit` / `work-merge` chain at a time in the
current conversation.

A future Pi adapter may be inserted here only when it documents named worker
dispatch, direct messaging, completion notification, resume, and stop semantics
for Pi. That adapter still uses bd as the task contract, Git as the source
contract, and AKM as the knowledge contract; it does not use [[ft012]] or
Claude agent-census output as runtime detection.

#### Unsupported runtime

If neither `AI_AGENT=pi` nor the Claude native branch is available, stop with
`unsupported-runtime` and name the missing orchestration surface. Do not fall
through to the Claude instructions.

For the rationale (why a wrapper agent cannot do this) and the full Claude
dispatch contract, see `references/architecture.md`.

## Prerequisites

Two mandatory gates must have been passed:

1. **⛔ Spec approved by user** — the spec/plan document was reviewed and explicitly approved.
2. **⛔ bd tasks approved by user** — the bd task list was reviewed and explicitly approved.

If either gate was not passed, STOP and go back. Starting execution before both approvals means the agents will burn tokens on work the human has not yet sanctioned.

Additionally:
- bd tasks are created with designs and dependencies.
- `bd ready` returns at least one task.

## Configuration

Three settings, provided by the human at start. If any are missing, **ask** — but offer the defaults below as the "use defaults" option. The defaults are tuned for a typical session: moderate parallelism, only halt on real problems, cheap model first with automatic escalation on failure.

| Setting | Default | Options |
|---------|---------|---------|
| `max_parallel` | **2** | 1, 2, 3, ... N, or `all` |
| `mode` | **only-blockers** | `auto`, `waves`, `only-blockers` — see `references/modes.md` |
| `worker_model` | **sonnet** | `opus`, `sonnet`, `haiku`, `auto` — see `references/worker-models.md` |

### Failure-escalation rule (always on)

When `worker_model` is `sonnet` or `haiku`, the scrum-master **upgrades the model on retry** after any of: implementer error/timeout, first reviewer rejection, or implementer `blocked` status. The retry uses `opus` regardless of the configured `worker_model`. Rationale: the cheap model gets one fair attempt; if it fails, throwing more capability at the problem is usually faster than the human debugging why it stumbled.

The upgrade applies only to the *retry* dispatch — subsequent tasks return to the configured `worker_model`. If `worker_model` is already `opus` or `auto`, no upgrade is needed.

Always echo the chosen settings (and the escalation rule) in the dispatch summary so the human can override before confirming.

## Multi-Epic Parallelism

When multiple epics have ready tasks, tasks from different epics can run in parallel **only if they don't touch overlapping files or directories**. Run an interference check: read each epic's spec, compare file paths, and group non-interfering epics for parallel dispatch. If unsure, ask the human — guessing here causes merge conflicts in worktrees.

For the full rule set + examples, see `references/multi-epic.md`. Present the interference assessment in every dispatch summary (write `n/a — single epic` when only one is active).

## State Machine

### Task state (scrum-master observes, agents perform)

```
open → in_progress    Implementer agent (claims the task)
in_progress → closed  Reviewer agent (verifies, merges, and closes)
in_progress → blocked Implementer agent (needs info, can't proceed)
```

### Epic state (scrum-master owns open → in_progress + P2 → P1)

```
open → in_progress    Scrum-master (on first task dispatch of this epic)
in_progress → closed  spec-retro skill (after merge / PR)
```

**Priority also escalates on dispatch:** epic and all child tasks go from P2 → P1 (actively in flight). See "Activate the epic" in Step 3 for commands.

**Why scrum-master owns the activation:** dispatch is the moment work starts — the state flips from "planned and waiting" to "in flight." Status `in_progress` and priority `P1` both encode that. Nobody else is watching for this moment: `spec-ready` sets up the P2/open snapshot and walks away, `work-do` only touches its own task, `work-audit` closes individual tasks, and `spec-retro` runs much later at delivery time. The scrum-master is the first actor that "knows" the epic is alive.

**When to transition:** right before dispatching the first implementer for a task whose parent epic is still `open` / P2. Run the `bd update` commands before the `Agent` call. If the epic is already `in_progress` / P1 from a previous session, leave it alone.

**Epic close stays with spec-retro** — do NOT close epics from this skill. The retro step validates the work, writes the learning notes, and archives the spec. Closing early would skip that.

### Full lifecycle priority map

| Stage | Skill | Epic priority | Epic status | Child tasks |
|-------|-------|---------------|-------------|-------------|
| Idea | `idea-brainstorming` | P4 | open | — |
| Spec | `spec-writing` | P3 | open | — |
| Ready | `spec-ready` | P2 | open | P2 / open |
| **Dispatched** | **`plan-scrum-master`** | **P1** | **in_progress** | **P1** |
| Retro | `spec-retro` | — | closed | (already closed by work-audit) |

## The Process

```dot
digraph scrum_master {
    rankdir=TB;

    "Orient: bd ready, bd stats" [shape=box];
    "Show dispatch summary + ask confirmation" [shape=box];
    "Human confirms?" [shape=diamond];
    "Any tasks ready?" [shape=diamond];
    "Pick up to max_parallel tasks" [shape=box];
    "Dispatch implementer agent(s)\n(Claude native branch only)" [shape=box];
    "Collect implementer report(s)" [shape=box];
    "Relay to reviewer agent(s)\n(Claude native branch only): task spec + report" [shape=box];
    "Reviewer result?" [shape=diamond];
    "Re-dispatch implementer with rejection details" [shape=box];
    "Rejected twice?" [shape=diamond];
    "Escalate to human" [shape=box style=filled fillcolor=lightyellow];
    "Report batch progress" [shape=box];
    "Mode = waves?" [shape=diamond];
    "Wait for human feedback" [shape=box];
    "All tasks done?" [shape=diamond];
    "Final summary" [shape=box style=filled fillcolor=lightgreen];

    "Orient: bd ready, bd stats" -> "Show dispatch summary + ask confirmation";
    "Show dispatch summary + ask confirmation" -> "Human confirms?";
    "Human confirms?" -> "Any tasks ready?" [label="yes"];
    "Human confirms?" -> "Final summary" [label="no — abort"];
    "Any tasks ready?" -> "Pick up to max_parallel tasks" [label="yes"];
    "Any tasks ready?" -> "Final summary" [label="no — all closed"];
    "Any tasks ready?" -> "Escalate to human" [label="no — but open tasks exist"];
    "Pick up to max_parallel tasks" -> "Activate parent epic if still 'open'";
    "Activate parent epic if still 'open'" [shape=box];
    "Activate parent epic if still 'open'" -> "Dispatch implementer agent(s)\n(Claude native branch only)";
    "Dispatch implementer agent(s)\n(Claude native branch only)" -> "Wait for agent notifications";
    "Wait for agent notifications" [shape=box style=filled fillcolor=lightyellow];
    "Wait for agent notifications" -> "Collect implementer report(s)" [label="implementer done"];
    "Collect implementer report(s)" -> "Relay to reviewer agent(s)\n(Claude native branch only): task spec + report";
    "Relay to reviewer agent(s)\n(Claude native branch only): task spec + report" -> "Reviewer result?";
    "Reviewer result?" -> "Report batch progress" [label="approved + closed"];
    "Reviewer result?" -> "Re-dispatch implementer with rejection details" [label="rejected"];
    "Re-dispatch implementer with rejection details" -> "Rejected twice?";
    "Rejected twice?" -> "Relay to reviewer agent(s)\n(Claude native branch only): task spec + report" [label="no — retry"];
    "Rejected twice?" -> "Escalate to human" [label="yes"];
    "Report batch progress" -> "Mode = waves?";
    "Mode = waves?" -> "Wait for human feedback" [label="yes"];
    "Mode = waves?" -> "All tasks done?" [label="no"];
    "Wait for human feedback" -> "All tasks done?";
    "All tasks done?" -> "Orient: bd ready" [label="no"];
    "All tasks done?" -> "Final summary" [label="yes"];
}
```

## Step 1: Orient

```bash
bd ready                              # What's available?
bd list --type epic --status open     # Which epics are active?
bd list --status in_progress          # Anything mid-flight from previous session?
bd stats                              # Overall picture
```

If `in_progress` tasks exist from a previous session, escalate to human — ask whether to resume or reset them. Do not silently retry; a stale `in_progress` may mean the previous agent crashed mid-merge and the worktree is in an unknown state.

**Multiple epics:** If more than one epic has ready tasks, perform the interference check (`references/multi-epic.md`). Group non-interfering epics for parallel dispatch.

## Step 2: Dispatch Summary

Before dispatching anything, present a summary to the human and ask for confirmation:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DISPATCH SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Board:
  Total tasks:    X
  Ready:          Y
  In progress:    Z
  Blocked:        W
  Closed:         V

Active epics:
  bd-AAAA: [epic title]  — targets: app/auth/, app/models/user.ts
  bd-BBBB: [epic title]  — targets: app/billing/, app/models/invoice.ts

Interference:
  bd-AAAA ↔ bd-BBBB: NONE — can parallel
  (or: CONFLICT on app/shared/config.ts — must serialize)
  (or: n/a — single epic)

Ready queue:
  [bd-AAAA] bd-XXXX: [title]
  [bd-AAAA] bd-YYYY: [title]
  [bd-BBBB] bd-ZZZZ: [title]

Dependencies:
  [summary of key chains — use `bd list --parent <epic-id>` for the child list
   and `bd dep tree <task-id> --direction=both` for per-task view]

Config:
  max_parallel:   N                  (default 2)
  mode:           only-blockers      (default — pause on failures only)
  worker_model:   sonnet             (default; opus on retry after any failure)

First batch (up to max_parallel):
  → bd-XXXX: [title]  (epic bd-AAAA)  model: sonnet  [default — retry will upgrade to opus]
  → bd-ZZZZ: [title]  (epic bd-BBBB)  model: sonnet  [default — retry will upgrade to opus]

Proceed? (yes / adjust config / abort)
```

Wait for human confirmation before dispatching. The human may adjust `max_parallel`, `mode`, or ask to skip/reorder tasks.

## Step 3: Dispatch Implementers

Pick up to `max_parallel` tasks from `bd ready`. When multiple non-interfering epics are active, mix tasks from different epics in the same batch.

### Activate the epic (first task only)

Before dispatching the first task of an epic, transition the epic to `in_progress` and bump priority to P1 — both the epic and all its child tasks go to P1 to signal "actively in flight":

```bash
bd show <epic-id>                                # Check current status + priority
bd update <epic-id> --status in_progress --priority 1    # Only if still 'open' / P2

# Bump all child tasks to P1 in one pass
bd list --parent <epic-id> --status open --json | jq -r '.[].id' \
  | xargs -I{} bd update {} --priority 1
```

**Why P1 for both epic and child tasks:** priority tracks lifecycle commitment (P4 idea → P3 spec → P2 ready → P1 in flight). Bumping the whole subtree to P1 on dispatch means `bd list --priority 1` surfaces exactly what is being worked on *right now*. If tasks stay at P2 after dispatch, the priority field loses its signal.

Skip this if the epic is already `in_progress` / P1 (e.g., resumed session). Do this once per epic, not per task. If some child tasks already have a higher-priority override (P0 — urgent), leave those alone.

### Dispatch the task

Claude native branch only: for each task, run `bd show <id>` and dispatch an `Agent` tool call with `name: "impl-<bd-id>"` (no `run_in_background` — subagents are background by default; no `isolation: "worktree"` — that auto-generates an opaque dir name; the implementer creates its own worktree at the right name per work-do Step 2). In Pi, do not use this section unless a Pi multi-worker adapter has replaced the Claude tool names with its own supported surface. The dispatch payload contains:

1. **Task ID and title**
2. **Full design text** from `bd show` (paste it — don't make agent query bd)
3. **Context** — what tasks were recently completed, what else is in the pipeline
4. **Branch + worktree name to use:** both `bd-<id>.<N>`. `<N>` is the iteration computed by work-do's picker (`.0` on first attempt, increment on retry). Path = `$AKM_ROOT/.worktrees/bd-<id>.<N>`. The implementer creates the worktree itself with `git worktree add` so the dir name matches the branch name — work-merge and the spec-retro safety-net sweep both key off `bd-<id>` branches, and the matching dir name makes `git worktree list` self-documenting.
5. **Mandatory rule:** "NEVER use `cd path && command` in bash — always use absolute paths. `cd &&` triggers user confirmation prompts that block background agents."

**The implementer is responsible for:**
- Claiming the task: `bd update <id> --status in_progress`
- **Creating its own worktree** at `$AKM_ROOT/.worktrees/bd-<id>.<N>` on branch `bd-<id>.<N>` via `git worktree add` (per work-do Step 2). Do NOT rely on `isolation: "worktree"` — opaque dir names break the dir-to-task mapping the cleanup sweeps depend on.
- `cd` into the newly-created worktree; do all work there
- Implementing, testing, committing in the worktree
- Do NOT merge — reviewer will handle that
- Reporting back: what it did, branch name (`bd-<id>.<N>`), absolute worktree path, test results, concerns
- Marking blocked if it can't proceed: `bd update <id> --status blocked`
- **NEVER use `cd ... &&` in bash commands** — use absolute paths instead (triggers extra user confirmation, breaks background flow)

**Claude native branch:** dispatch up to `max_parallel` agents in a single message, each with its own `name`. Do NOT poll or sleep — you will be automatically notified when each agent completes. While waiting, you may report status or respond to the human.

**Pi branch:** if no explicit Pi multi-worker adapter is installed, do not dispatch multiple workers. Return `unsupported-runtime: plan-scrum-master multi-worker dispatch requires [[sp028]] or another Pi adapter` and offer the sequential `plan-supervised` path for one task at a time.

**Save agent session metadata** after each `Agent` call returns:
- **Agent name** (`impl-<bd-id>`) — the address for `SendMessage` / `TaskStop`. Names keep working after the agent completes; a send resumes it from its transcript.
- **Agent ID** (`a...-...`) — fallback address only, for when a name was not set or a newer agent took the name (latest wins)
- **Worktree path** — for reviewers to inspect the code
- **Branch name** — for reviewers to merge

Log these to bd notes: `bd update <id> --notes "Agent session: [id], worktree: [path], branch: [branch]"`

This enables resuming agents on rejection instead of dispatching fresh ones — the original agent retains its full context.

## Step 4: Relay to Reviewer

Claude native branch only: when notified that an implementer has completed, dispatch a reviewer agent with `name: "rev-<bd-id>"` and `subagent_type: "infinifu:code-reviewer"`. In Pi, use the installed Pi adapter's reviewer dispatch surface; without one, stop and route to sequential `plan-supervised` instead:

1. **Task spec** — the original design text from bd
2. **Implementer's full report** — pass through as-is, including any metadata (paths, branches, etc.)

You do not interpret the report. You relay it. Do NOT wait for the reviewer — you will be notified when it completes. Continue processing other notifications or dispatching new implementers in the meantime.

**The reviewer is responsible for:**
- Invoking `infinifu:work-audit` against the task — that skill owns the verdict, the `bd close` on approve, and the auto-trigger of `infinifu:work-merge` for per-task local landing
- Reading actual code in the implementer's worktree as part of work-audit's evidence-gathering
- **work-audit on APPROVED auto-fires work-merge**, which: merges `bd-<id>` into base locally with `--no-ff`, runs the post-merge test gate, removes the worktree + local branch, and (if this was the last open child of the epic) flips the AKM lifecycle + moves board→archive + closes the bd epic. All local — no push. spec-retro syncs to remote later.
- Closing the task happens inside work-audit (`bd close <id> --reason "AUDITED: APPROVED ..."`); reviewer does not call `bd close` directly
- **NEVER use `cd ... &&` in bash commands** — use absolute paths instead (triggers extra user confirmation, breaks background flow)
- If rejected (verdict from work-audit OR `POST-MERGE FAIL` from work-merge converted back to rejection):
  - work-audit / work-merge already updated bd notes with `Gaps:` or `POST-MERGE FAIL:` evidence
  - Reporting the rejection details (gaps, requested action) to scrum master so the implementer can be re-dispatched

## Step 5: Handle Rejections and Failures

The retry rule covers three failure modes: reviewer rejection, implementer error/timeout, and implementer-reported `blocked`. All three follow the same escalation pattern.

1. **First failure (rejection / error / blocked):**
   - If a reviewer rejection: reviewer updates bd with `--design` (new conditions) and `--notes` (rejection reason).
   - If an implementer error or `blocked`: log the implementer's reason to `--notes`.
   - **Model upgrade:** if the original `worker_model` was `sonnet` or `haiku`, the retry uses `opus` (see "Failure-escalation rule" in Configuration). If it was already `opus` or `auto`, keep the same model.
   - **Claude native branch:** resume the original implementer via `SendMessage({to: "impl-<bd-id>", message: ...})` using its saved name — pass the failure details. The agent retains its full context and is already in the worktree. Resume preserves cheap context; only dispatch a fresh agent if the original session cannot be resumed (e.g., expired) or if the model is being upgraded across providers and a session swap is required. Pi may use only an installed Pi adapter's resume command; without that adapter, stop and defer multi-worker retry to [[sp028]].
   - When notified of completion, dispatch reviewer again (also in background).
2. **Second failure on the same task:** Escalate to human — the task needs human attention. Do not retry a third time silently.

Log the retry decision in the bd notes so a later auditor can see why the model jumped (`bd update <id> --notes "Retry attempt 2: upgraded sonnet → opus after reviewer rejection"`).

## Step 6: Report

After each batch:

```
Batch N:
  ✅ bd-XXXX: [title] — [summary from report]
  ✅ bd-YYYY: [title] — [summary from report]
  ❌ bd-ZZZZ: [title] — ESCALATED: [reason]

Pipeline: X/Y tasks done | Z ready | W blocked
```

**If mode = `waves`:** Say "Ready for feedback." and wait for human input.
**If mode = `auto` or `only-blockers`:** Continue to next batch.

See `references/modes.md` for the full mode semantics.

## Step 7: Loop or Finish

- **`bd ready` returns tasks** → go to Step 3
- **All tasks closed** → report final summary and run `bd stats` (bd 1.0 auto-exports `.beads/issues.jsonl`; no separate `bd sync` needed)
- **Open tasks exist but none ready** → escalate (dependency issue or blocked tasks)

## Agent Health Monitoring

Alert the user immediately when any agent shows signs of struggling — long runtime vs peers, verbose / partial reports, self-reported uncertainty, or a `blocked` marker. Do not defer alerts to the next batch report; a stuck agent burns tokens until killed.

See `references/agent-health.md` for the full signal list and the alert template.

## Escalation Protocol

**STOP and escalate when:**
- Implementer agent fails or returns an error
- Reviewer rejects the same task twice
- Task has no design or vague design in bd
- Implementer marks task as blocked
- Agent shows signs of struggling (see `references/agent-health.md`)
- `bd ready` is empty but open tasks remain
- Any unexpected agent behavior

**Format:**
```
BLOCKED: bd-XXXX "[task title]"
Reason: [what the agent reported]
Attempts: [what was tried]
Options: [suggested next steps]
Need your decision to continue.
```

## What You Do Touch vs. What You Don't

**You own:**
- Reading the board (`bd ready`, `bd list`, `bd show`, `bd stats`)
- Epic state: `open → in_progress` on first dispatch (close is NOT yours — spec-retro handles it)
- Logging dispatch metadata to bd notes (agent id, worktree path, branch)

**You never:**
- Write code, edit files, or run tests
- Touch git, branches, worktrees, or merges — you stay on main
- Create or manage worktrees — implementer creates its own worktree per work-do Step 2 (with the matching `bd-<id>.<N>` dir name); reviewer's work-audit → work-merge handles removal on approve
- Claim or close **tasks** — implementer sets `in_progress`, reviewer closes
- Close **epics** — spec-retro owns that (after merge)
- Analyze code, detect file conflicts, or review implementations
- Decide technical approach for agents
- Interpret agent metadata — just relay it

## Integration

**Depends on:**
- **infinifu:spec-ready** — creates the bd tasks and promotes spec to ready; reference for bd commands
- **infinifu:spec-writing** — creates the plan this skill orchestrates

**Implementer agents are dispatched without `isolation: "worktree"` (they create their own worktree at `bd-<id>.<N>` per work-do Step 2) and should use:**
- **infinifu:work-do** — per-task protocol (read `bd show`, claim, implement, close with evidence, report back)
- **infinifu:domain-tdd** — invoked by work-do for RED-GREEN-REFACTOR

**Reviewer agents should use:**
- **infinifu:work-audit** — per-task verification gate. Auto-triggers work-merge on the APPROVED verdict.
- **infinifu:work-merge** (auto-triggered, not invoked directly) — per-task local land + worktree cleanup; epic finale (AKM flip + board→archive + bd close epic) on the last open child.

**After every pipeline task lands and the epic finale has fired:**
- **infinifu:spec-retro** — refreshes the AKM graph (im### body rewrite, new ADRs, ft### updates, us### drafts) and pushes everything to remote (`git push` + `bd dolt push`). work-merge stayed local; this is where remote sync happens.
