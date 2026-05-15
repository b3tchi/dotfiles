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

If the user provided arguments (e.g., `/dispatch-fnf max_parallel=3 mode=waves`), use them as configuration. Otherwise, ask the user before starting:

1. **max_parallel** — how many agents to run simultaneously? (1, 2, 3, ... or all)
2. **mode** — `auto` (continuous), `waves` (pause between batches), or `only-blockers` (pause on failures only)
