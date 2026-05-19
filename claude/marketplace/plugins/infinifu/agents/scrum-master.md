---
name: scrum-master
description: |
  DEPRECATED — do not dispatch. Scrum-master pipeline orchestration must run inline in the main Claude session via the `infinifu:plan-scrum-master` skill, not as a nested agent. Claude Code's harness blocks sub-agents from dispatching further sub-agents, so a wrapper agent cannot spawn implementer or reviewer workers. If a user asks to "dispatch the scrum-master agent," redirect them to Pattern A: invoke `/plan-dispatch-fnf` (or call the `plan-scrum-master` skill directly) in the current session. Examples: <example>Context: User asks to dispatch scrum-master as an agent. user: "Dispatch the scrum-master agent to orchestrate the pipeline." assistant: "The wrapper agent is deprecated — nested agent dispatch is blocked. I'll invoke the `plan-scrum-master` skill here in the main session instead." <commentary>Redirect to Pattern A; the wrapper cannot spawn workers.</commentary></example>
model: inherit
---

# DEPRECATED

This agent is deprecated. The `plan-scrum-master` skill must run inline in the main Claude session, not as a dispatched sub-agent.

## Why

Claude Code's harness does not allow a sub-agent to dispatch further sub-agents. The scrum-master's job is to dispatch implementer and reviewer workers — if it runs inside a wrapper agent, the workers can't be spawned. Confirmed blocker in practice.

## What to do instead

Invoke the `infinifu:plan-scrum-master` skill in the main session:

- Via slash command: `/plan-dispatch-fnf [max_parallel=N] [mode=auto|waves|only-blockers]`
- Or invoke the `Skill` tool with `skill: infinifu:plan-scrum-master`

Main Claude becomes the scrum-master, dispatches workers as background subagents, and interacts with the user directly — no relay needed.

## If you are this agent despite the deprecation

Return immediately to the parent with this message:

> "Scrum-master wrapper agent is deprecated — nested agent dispatch is blocked. Please invoke `infinifu:plan-scrum-master` directly in the main session."

Do not attempt to dispatch workers from here; they cannot be spawned.
