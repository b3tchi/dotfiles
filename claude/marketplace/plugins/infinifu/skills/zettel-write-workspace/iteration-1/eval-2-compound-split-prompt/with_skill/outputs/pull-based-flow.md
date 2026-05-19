---
aliases:
  - pull-based flow — downstream signals capacity, upstream never pushes
created: 2026-05-15
---
# Pull-based flow [[product]]

In a pull system, downstream stages signal readiness and upstream only releases work in response; in a push system, upstream releases on its own schedule and downstream absorbs whatever arrives. Pull self-regulates to actual capacity because the slowest stage governs intake — there is no way to accumulate hidden queues without someone refusing to pull. Push optimises local throughput at the cost of system-wide queueing, latency, and rework.

## see also
- [[wip-limits]]
- [[circuit-breaker]]

---

Index: [[product]]
