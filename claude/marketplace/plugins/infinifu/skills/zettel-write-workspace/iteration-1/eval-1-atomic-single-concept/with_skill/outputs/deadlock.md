---
aliases:
  - deadlock — mutual hold-and-wait between threads
created: 2026-05-15
---
# Deadlock [[product]]

A state where two or more threads each hold a resource the other needs and none can proceed. Distinct from livelock (threads keep moving but make no progress) and from simple contention (one waiter, one holder, eventually drains). Detection at runtime is expensive, so the usual cure is prevention: a global lock order, try-lock with timeout, or removing shared mutable state on the hot path. Surfaced for us during the payment-queue incident, where two workers each held one half of a paired resource.

## see also
- [[circuit-breaker]]
- [[on-call-rotation]]

---

Index: [[product]]
