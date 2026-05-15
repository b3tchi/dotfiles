---
aliases:
  - optimistic locking — detect-on-commit concurrency control
created: 2026-05-15
---
# Optimistic locking [[product]]

Let concurrent transactions read freely; detect conflict at commit time via a version column or row-hash, and force the loser to retry. No row-level locks are held during the read-modify-write window, so contention cost only shows up when conflicts actually occur. Fits workloads where conflicts are rare relative to read volume — the common case is cheap, the rare collision pays a retry. When conflict rate climbs toward double-digit percent of writes, retries dominate and the pattern inverts; that's the signal to compare against [[pessimistic-locking]] for the same access path.

## see also
- [[pessimistic-locking]]
- [[circuit-breaker]]

---

Index: [[product]]
