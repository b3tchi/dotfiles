---
description: Dispatch agents to bd ready tasks — scrum master pipeline orchestration
disable-model-invocation: true
---

Before doing anything else, print this phase banner exactly:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PHASE: DISPATCH
  Scrum master dispatching agents to bd pipeline
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Then invoke the infinifu:plan-scrum-master skill and follow it exactly as presented to you.

If the user provided arguments (e.g., `/plan-dispatch-fnf max_parallel=3 mode=waves worker_model=sonnet`), use them as configuration. Otherwise, ask the user — and offer the defaults below as the "use defaults" option:

1. **max_parallel** — how many agents to run simultaneously? Default: **2**. Other: 1, 3, ... or `all`.
2. **mode** — Default: **only-blockers** (pause on failures only). Other: `auto` (continuous), `waves` (pause between batches).
3. **worker_model** — Default: **sonnet**. Other: `auto` (pick per task complexity), `opus`, `haiku`.

**Failure-escalation rule (always on):** when `worker_model` is `sonnet` or `haiku`, the scrum-master automatically upgrades the model to `opus` on retry after any failure (rejection, error, blocked). Flag this in the dispatch summary so the human sees the cost implication.
