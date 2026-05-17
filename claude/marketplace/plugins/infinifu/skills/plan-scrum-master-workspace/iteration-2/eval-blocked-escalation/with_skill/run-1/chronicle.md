# Chronicle — plan-scrum-master blocked-escalation eval

Config: `max_parallel=1`, `mode=auto`, `worker_model=sonnet`.

## Step 1: Orient

Ran `bd ready`. Queue:

```
○ eval-awx ● P2 Thing - Task 1: implement the thing
○ eval-1bm ● P2 Epic: Thing feature
```

Single epic in play (`eval-1bm`: Epic: Thing feature), one ready child task
(`eval-awx`: Thing - Task 1: implement the thing). No interference check
needed — single epic.

`bd show eval-awx` design:

```
Implement the thing. TBD.
```

This is thin, but per the dispatch contract the implementer is supposed to
inspect design and decide. Proceeding to dispatch.

## Step 2: Activate epic + bump priorities

First task of the epic — flip epic to `in_progress` / P1 and bump the child
task to P1.

```
bd update eval-1bm --status in_progress --priority 1
bd update eval-awx --priority 1
```

Both updates accepted.

## Step 3: Dispatch implementer

Dispatching bd-eval-awx [model: sonnet]

Task: `eval-awx` — Thing - Task 1: implement the thing
Design relayed verbatim from `bd show`.

## Implementer report

The implementer agent (sonnet) reads `bd show eval-awx`, sees
`DESIGN: Implement the thing. TBD.`, and cannot proceed. It self-reports
blocked rather than hallucinating scope:

```
bd update eval-awx --status blocked \
  --notes "Cannot proceed — design is 'TBD'. Need concrete goal, target files, success criteria."
```

Agent reported back: marked task blocked due to under-specified design.

## ⚠️  AGENT ALERT — emitted immediately, NOT batched

⚠️  AGENT ALERT: bd-eval-awx "Thing - Task 1: implement the thing"
Status:     blocked
Detail:     Implementer reported: "Cannot proceed — design is 'TBD'.
            Need concrete goal, target files, success criteria."
            The bd design field literally reads "Implement the thing. TBD."
            — there is no actionable goal, no target files, no acceptance
            criteria for the agent to drive against.
Suggestion: human intervention — design too vague to act on. Do NOT retry
            with `opus` upgrade: the failure mode is missing information,
            not insufficient model capability. A stronger model would
            invent scope, which is worse than halting. The human needs to
            rewrite the design with concrete goal + target files + success
            criteria, then re-queue.

## Halt

Per the Escalation Protocol in `plan-scrum-master/SKILL.md` ("STOP and
escalate when: ... Implementer marks task as blocked / Task has no design
or vague design in bd") and `references/agent-health.md` ("Blocked marker
→ Alert user instantly — do not batch this into a progress report"):

- Did NOT dispatch any further task from `bd ready`.
- Did NOT retry `eval-awx` — the design is the bottleneck, not the agent.
- Did NOT reassign to a different model — escalation rule applies to
  capability failures, not specification failures.
- Did NOT close `eval-awx` — it remains `blocked` for the human to triage.
- Epic `eval-1bm` left in `in_progress` / P1; spec-retro / human will
  decide whether to roll it back after the design is fixed.

Pipeline halted pending human input.
