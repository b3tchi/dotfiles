# Architecture: why scrum-master runs inline

This reference documents the **Claude native branch** of the scrum-master
runtime adapter. It is not a Pi runtime detector, and it must not be applied
under `AI_AGENT=pi` unless a Pi adapter explicitly maps each operation below to
its own supported surface.

The main Claude session is the scrum-master. The user invokes the skill directly (`/plan-dispatch-fnf` or equivalent) and talks to the orchestrator as themselves. No wrapper agent.

- Main Claude holds the dispatch loop, shows summaries, asks confirmations, handles waves feedback, reports progress — all in the live conversation.
- **Workers (implementers + reviewers) are dispatched as named background subagents** via the `Agent` tool (`name: "impl-<bd-id>"` / `"rev-<bd-id>"`). Each implementer creates its own git worktree at `bd-<id>.<N>` as part of work-do Step 2 (Claude Code's `isolation: "worktree"` shortcut is not used because the auto-generated dir name is opaque and breaks the dir-to-task mapping that the cleanup sweeps depend on).
- Main Claude receives completion notifications from each worker and reacts (relay to reviewer, handle rejection, report batch).
- While workers run, the user can still interrupt, ask questions, adjust config — the main session stays responsive because the workers are in the background.

## Why inline only

Claude Code's harness does not allow sub-agents to dispatch further sub-agents (no nested-agent recursion). That means the scrum-master must run at the top level — the session that holds the dispatch loop must also be the session that has `Agent`-tool access to workers. A wrapper `infinifu:scrum-master` agent cannot dispatch implementers from inside its own context; structural block confirmed in testing.

If you see the deprecated `infinifu:scrum-master` wrapper agent referenced anywhere, use the inline pattern (this skill in main Claude) instead.

## Worker dispatch contract

Claude native branch only:

- **No `isolation: "worktree"`** — the implementer creates its own git worktree at `bd-<id>.<N>` (matching branch name) so `git worktree list` is self-documenting and the cleanup sweeps in work-merge + spec-retro can map dir → task mechanically.
- `name` — **required on every dispatch.** `impl-<bd-id>` for implementers, `rev-<bd-id>` for reviewers. Names must match `[A-Za-z0-9][A-Za-z0-9_-]{0,63}` (no dots — do NOT append the worktree iteration `.N`). On a fresh retry dispatch that must coexist with the original, suffix `-r2`.
- `subagent_type` — `general-purpose` for implementers, `infinifu:code-reviewer` for reviewers.
- **No `run_in_background`** — the `Agent` tool has no such parameter and neither does `SendMessage`. Subagents always run in the background; passing it is an input-validation error.
- **No `team_name`** — deprecated and ignored. The session has a single implicit team; the `name` is the whole addressing story.

The orchestrator does **not** poll or sleep — it reacts to completion notifications.

## Agent teams: the addressing contract

Naming the workers is what makes the pipeline a team rather than a set of fire-and-forget calls:

| Need | Call |
|------|------|
| Roster + busy/idle state of live workers | `ListAgents` |
| Send a rejection back to the original implementer | `SendMessage({to: "impl-<bd-id>", message: "..."})` |
| Reply to a message a worker sent you | copy the incoming `from` attribute into `to` |
| Kill a stuck worker | `TaskStop({task_id: "impl-<bd-id>"})` |

A worker can also reach the orchestrator mid-run with `SendMessage({to: "main", ...})` — that is the channel for a blocked implementer that wants a decision without ending its turn. Worker prose is not visible to anyone else; only `SendMessage` crosses the boundary.

Names survive completion: a send to a completed agent's name resumes it from its transcript, which is exactly what the rejection-retry path in Step 5 relies on. Use the raw `agentId` only when no name was set, or when a newer agent has taken the name (latest wins).

## Future Pi multi-worker adapter insertion point

The Pi branch starts sequential and unsupported for visible multi-worker
scrum-master dispatch. A later adapter may replace that behavior only if it
implements named worker dispatch, direct messaging, completion notification,
resume, and stop semantics with Pi-native commands. It must also keep the same
durable state model: bd for task contracts and notes, Git for source branches
and worktrees, and AKM for knowledge artifacts.

The adapter's runtime gate must be explicit (`AI_AGENT=pi` or a future declared
Pi capability flag). It does not use [[ft012]] or Claude census output as
runtime detection, and tmux remains only a process/display host unless the Pi
adapter separately documents a message bus.
