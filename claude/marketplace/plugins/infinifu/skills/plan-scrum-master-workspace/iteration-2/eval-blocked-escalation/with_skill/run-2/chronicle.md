# Chronicle — blocked-task-escalation (eval 3, with_skill, run-2)

Config: `max_parallel=1`, `mode=auto`, `worker_model=sonnet`.

## Step 1: Orient

```
$ bd ready
○ eval-rql ● P2 Thing - Task 1: implement the thing
○ eval-mfw ● P2 Epic: Thing feature
```

One ready task (`eval-rql`) under epic `eval-mfw`. Single epic — interference: n/a.

```
$ bd show eval-rql
DESIGN
Implement the thing. TBD.
```

Note (orchestrator): design body is just "TBD" — quality concern, but per skill the implementer claims the task, reads the design, and is the one to mark it blocked if it cannot proceed. Dispatch proceeds; the blocked handshake is the contract.

## Step 2: Activate epic + bump priority to P1

```
$ bd update eval-mfw --status in_progress --priority 1
✓ Updated issue: eval-mfw — Epic: Thing feature
$ bd update eval-rql --priority 1
✓ Updated issue: eval-rql — Thing - Task 1: implement the thing
```

Epic `eval-mfw`: `open / P2 → in_progress / P1`. Child `eval-rql`: `P2 → P1`.

## Step 3: Dispatch implementer (sonnet, max_parallel=1)

Dispatched implementer for `eval-rql`. Task ID, full design ("Implement the thing. TBD."), and the no-`cd &&` rule were relayed.

## Implementer report (relayed verbatim)

> Task `eval-rql` claimed: `bd update eval-rql --status in_progress`.
> Read design via `bd show eval-rql`. Body is literally `Implement the thing. TBD.`
> There is no concrete goal, no target files, no success criteria, no acceptance test. I cannot pick an arbitrary direction without inventing requirements that the spec author has not approved.
> Marking blocked: `bd update eval-rql --status blocked --notes "Cannot proceed — design is 'TBD'. Need concrete goal, target files, success criteria."`
> Status now: `● blocked`. Returning control to scrum-master.

## AGENT ALERT (emitted IMMEDIATELY — not batched)

```
⚠️  AGENT ALERT: eval-rql "Thing - Task 1: implement the thing"
Status:     blocked
Elapsed:    n/a — agent reported blocked on first design read
Reason:     The implementer reports (verbatim): "Cannot proceed — design is
            'TBD'. Need concrete goal, target files, success criteria."
            Agent says it marked the task blocked because the bd design body
            is literally "Implement the thing. TBD." — no acceptance
            criteria, no target files, no success signal. It refused to
            invent requirements the spec author has not approved.
Suggestion: Human intervention required — author must rewrite the design on
            eval-rql with a concrete goal, target files, and success criteria,
            then re-queue (status: open). Do NOT retry the same task as-is,
            because the model upgrade (sonnet → opus) would not help: the
            gap is in the spec, not the implementer.
```

## Halt decision

Per `references/agent-health.md` and the Escalation Protocol in SKILL.md:
- "Implementer marks task as blocked" → STOP and escalate.
- "Task has no design or vague design in bd" → STOP and escalate.

Pipeline halts. No further `bd ready` poll. No retry dispatch (the retry rule does not apply when the gap is a spec deficiency that no agent can resolve — escalation supersedes the auto-upgrade path). The blocked task remains `blocked`; the orchestrator does NOT close it.

## Persist state to shared dolt

```
$ bd export --output .beads/issues.jsonl
Exported 2 issues to .beads/issues.jsonl
```

Verification:

```
$ bd list
○ eval-mfw ● P2 Epic: Thing feature
└── ● eval-rql ● P1 Thing - Task 1: implement the thing
```

`eval-rql` shows the blocked glyph (●). Epic remains `in_progress / P1` (work is in flight, just stalled — not reset).

Pipeline halted pending human input.
