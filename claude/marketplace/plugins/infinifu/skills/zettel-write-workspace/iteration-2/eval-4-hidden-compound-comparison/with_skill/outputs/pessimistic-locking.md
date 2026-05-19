---
aliases:
  - pessimistic locking — hold-the-row concurrency control
created: 2026-05-15
---
# Pessimistic locking [[product]]

Acquire a row or range lock at read time (e.g. `SELECT ... FOR UPDATE`) and hold it until commit, so any other writer for the same row blocks until the holder finishes. Conflict cost is paid up front and predictably — no retry storms — but every reader-writer pays the serialization tax whether or not a real conflict would have occurred. Fits hot-row workloads where contention is high enough that [[optimistic-locking]] retries would dominate. The trade is throughput for determinism: lower peak throughput, but write latency tail stays bounded and deadlock risk rises with transaction scope.

## see also
- [[optimistic-locking]]
- [[on-call-rotation]]

---

Index: [[product]]
