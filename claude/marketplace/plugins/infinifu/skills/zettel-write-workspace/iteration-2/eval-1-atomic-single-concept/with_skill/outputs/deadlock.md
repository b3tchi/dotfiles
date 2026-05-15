---
aliases:
  - deadlock — mutual resource-hold between threads
created: 2026-05-15
---
# Deadlock [[product]]

A deadlock is the state where two or more threads each hold a resource the other one needs and none will release until they get the other's resource — so none ever progresses. Break the cycle by enforcing a global lock ordering, using timeouts on acquisition, or designing locks out of the hot path entirely. Surfaced in the payment-queue incident as a worker holding the queue lock while waiting on the DB connection pool that other workers held while waiting on the queue lock.

## see also
- [[circuit-breaker]]
- [[on-call-rotation]]

---

Index: [[product]]
