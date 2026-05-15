---
aliases:
  - deadlock — two threads each waiting on a resource the other holds
created: 2026-05-15
---
# Deadlock [[product]]

Two threads each hold a resource the other needs; neither releases, both wait forever.

## context

Surfaced during last week's payment-queue incident — useful to have a standalone card so we can link to it from postmortems and runbooks.

## see also
- [[circuit-breaker]] — fail-fast pattern that can shed load before contention turns into deadlock
- [[on-call-rotation]] — who gets paged when this kind of stall hits production

---

Index: [[product]]
