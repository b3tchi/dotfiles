---
aliases:
  - pull-based flow — downstream demand drives upstream work
created: 2026-05-15
---
# Pull-based flow [[product]]

In a pull-based system, work moves only when the downstream stage has capacity to take it; in a push-based system, upstream stages dispatch whenever they finish. Pull self-regulates to actual throughput because idle capacity is the signal, so queues stay short and overload surfaces as an upstream stall rather than a hidden backlog. Push tends to optimise local utilisation at the cost of end-to-end lead time. Pull pairs naturally with a [[wip-limits|WIP cap]] — the cap is what makes "downstream has capacity" a binary signal instead of a judgement call.

## see also
- [[wip-limits]]
- [[circuit-breaker]]

---

Index: [[product]]
