# Architecture: why scrum-master runs inline

This reference documents the orchestrator's own structure and dispatch
contract — process rules that hold no matter which runtime's cell actually
fills each operation. The concrete command for every operation named below
lives in `../meta-patterns/runtime-adapter.md`'s `## operation binding`;
this file never restates it.

The main session is the scrum-master. The user invokes the skill directly (`/plan-dispatch-fnf` or equivalent) and talks to the orchestrator as themselves. No wrapper agent.

- The main session holds the dispatch loop, shows summaries, asks confirmations, handles waves feedback, reports progress — all in the live conversation.
- **Workers (implementers + reviewers) are dispatched (operation: *dispatch*) as named background workers** (`name: "impl-<bd-id>"` / `"rev-<bd-id>"`). Each implementer creates its own git worktree at `bd-<id>.<N>` as part of work-do Step 2 — no isolation mode that hides the worktree behind an opaque path is used, because an auto-generated dir name is opaque and breaks the dir-to-task mapping that the cleanup sweeps depend on.
- The main session receives completion notifications (operation: *await*) from each worker and reacts (relay to reviewer, handle rejection, report batch).
- While workers run, the user can still interrupt, ask questions, adjust config — the main session stays responsive because *dispatch* never blocks waiting for a reply.

## Why inline only

The session running this skill must itself be able to invoke *dispatch* directly — and on Claude's native surface, a worker that was itself reached via *dispatch* cannot invoke *dispatch* again from inside its own context (no nested-agent recursion). That means the scrum-master must run at the top level: the session holding the dispatch loop must also be the session with *dispatch* access to workers. A wrapper `infinifu:scrum-master` agent is itself a dispatched worker, so it cannot dispatch implementers from inside its own context; structural block confirmed in testing.

If you see the deprecated `infinifu:scrum-master` wrapper agent referenced anywhere, use the inline pattern (this skill in main Claude) instead.

## Worker dispatch contract

Every dispatch (operation binding row `dispatch`) follows these rules:

- No isolation mode that hides the worktree behind an opaque path — the implementer creates its own git worktree at `bd-<id>.<N>` (matching branch name) so `git worktree list` is self-documenting and the cleanup sweeps in work-merge + spec-retro can map dir → task mechanically.
- A worker name is **required on every dispatch.** `impl-<bd-id>` for implementers, `rev-<bd-id>` for reviewers. Names must match `[A-Za-z0-9][A-Za-z0-9_-]{0,63}` (no dots — do NOT append the worktree iteration `.N`). On a fresh retry dispatch that must coexist with the original, suffix `-r2`.
- Implementer and reviewer are distinct worker roles running distinct skills (`work-do` vs `infinifu:code-reviewer`), not different dispatch mechanisms.
- Dispatch never blocks the orchestrator on a reply, and never carries a stateful session grouping of its own — the worker's *name* is the whole addressing story; nothing else is needed to route later operations to it.

The orchestrator does **not** poll or sleep — it reacts to *await* completion notifications.

## Worker addressing contract

Naming the workers is what makes the pipeline a team rather than a set of fire-and-forget calls:

| Need | Operation |
|------|------|
| Roster + busy/idle state of live workers | *inspect* |
| Send a rejection back to the original implementer | *reject/resume*, addressed by the worker's saved name |
| Reply to a message a worker sent you | address the reply back to whichever identity it sent from |
| Kill a stuck worker | *tear down*, addressed by the worker's saved name |

A worker can also reach the orchestrator mid-run to report being blocked and ask for a decision without ending its turn — that is the same addressed channel as *send work* / *await*, not a side door. Worker prose is not visible to anyone else; only an addressed message crosses the boundary.

Names survive completion: addressing a completed worker by its saved name resumes it from its transcript (operation: *reject/resume*), which is exactly what the rejection-retry path in Step 5 relies on. Fall back to a runtime-issued worker id only when no name was set, or when a newer worker has taken the name (latest wins).

## Multi-worker dispatch on other runtimes

The adapter this section used to await has shipped: `../meta-patterns/runtime-adapter.md`'s
`## operation binding` gives every lifecycle operation — dispatch, send work,
await, reject/resume, accept and clean, tear down, inspect — a concrete
command per runtime, so a runtime other than Claude's native surface fills
these same seven rows rather than needing a bespoke insertion point here. The
runtime gate stays explicit (`AI_AGENT=pi` or a future declared runtime flag,
per `## Runtime selection` in the binding file), the durable state model is
unchanged (bd for task contracts and notes, Git for source branches and
worktrees, AKM for knowledge artifacts), it does not use [[ft012]] or Claude
census output as runtime detection, and tmux remains only a process/display
host unless a runtime's adapter separately documents a message bus.

A future runtime is a new column on that table, not a new section here.
