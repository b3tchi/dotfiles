# Architecture: why scrum-master runs inline

The main Claude session is the scrum-master. The user invokes the skill directly (`/plan-dispatch-fnf` or equivalent) and talks to the orchestrator as themselves. No wrapper agent.

- Main Claude holds the dispatch loop, shows summaries, asks confirmations, handles waves feedback, reports progress — all in the live conversation.
- **Workers (implementers + reviewers) are dispatched as background subagents** via the `Agent` tool with `run_in_background: true`. Each implementer creates its own git worktree at `bd-<id>.<N>` as part of work-do Step 2 (Claude Code's `isolation: "worktree"` shortcut is not used because the auto-generated dir name is opaque and breaks the dir-to-task mapping that the cleanup sweeps depend on).
- Main Claude receives completion notifications from each worker and reacts (relay to reviewer, handle rejection, report batch).
- While workers run, the user can still interrupt, ask questions, adjust config — the main session stays responsive because the workers are in the background.

## Why inline only

Claude Code's harness does not allow sub-agents to dispatch further sub-agents (no nested-agent recursion). That means the scrum-master must run at the top level — the session that holds the dispatch loop must also be the session that has `Agent`-tool access to workers. A wrapper `infinifu:scrum-master` agent cannot dispatch implementers from inside its own context; structural block confirmed in testing.

If you see the deprecated `infinifu:scrum-master` wrapper agent referenced anywhere, use the inline pattern (this skill in main Claude) instead.

## Worker dispatch contract

- **No `isolation: "worktree"`** — the implementer creates its own git worktree at `bd-<id>.<N>` (matching branch name) so `git worktree list` is self-documenting and the cleanup sweeps in work-merge + spec-retro can map dir → task mechanically.
- `run_in_background: true` — orchestrator stays free to handle other notifications, talk to user, dispatch more work.
- `subagent_type` — `general-purpose` for implementers, `infinifu:code-reviewer` for reviewers.

The orchestrator does **not** poll or sleep — it reacts to completion notifications.
