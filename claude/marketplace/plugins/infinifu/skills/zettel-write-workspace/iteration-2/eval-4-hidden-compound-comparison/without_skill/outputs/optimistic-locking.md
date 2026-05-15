---
aliases:
  - optimistic locking — version-check on write, retry on conflict
created: 2026-05-15
---
# Optimistic locking [[product]]

Read row + version; on update assert version unchanged; bump version. Conflict → caller retries. No DB-side lock held between read and write.

## vs pessimistic locking

- **Pessimistic**: `SELECT ... FOR UPDATE` holds a row lock for the txn duration. Writers serialize, readers may block. Safe under heavy contention but throttles throughput and risks deadlock.
- **Optimistic**: no lock held; conflict detected at commit via version/timestamp column. Cheap on the happy path, expensive when conflicts are frequent (retry storm).

## fit for inventory service

- Most SKUs are touched by one writer at a time → low contention → optimistic wins (no lock overhead, better throughput).
- Hot SKUs (flash sale, single popular item) → contention spikes → optimistic degrades into retry loops → pessimistic or a queue in front is safer for those rows.
- Rule of thumb: optimistic if conflict rate < ~10%, pessimistic above that.

## see also
- [[circuit-breaker]]

---

Index: [[product]]
