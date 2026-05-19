# Summary

Captured a quick knowledge note on optimistic vs pessimistic locking, framed by the inventory service review that prompted it.

## Artifact

- `outputs/optimistic-locking.md` — zettel-style note matching the vault's existing convention (frontmatter with `aliases` + `created`, H1 with `[[product]]` backlink, short body, `see also` section, `Index: [[product]]` footer).

## Note content

- Defined optimistic locking as version-check-on-write with caller-side retry, no held lock.
- Contrasted with pessimistic locking (`SELECT ... FOR UPDATE`, serialized writers, deadlock risk).
- Applied to the inventory service contention profile: optimistic fits most SKUs (low contention, high throughput); pessimistic or a queue is safer for hot SKUs (flash sales) where retry storms would dominate.
- Gave a rough decision threshold (~10% conflict rate) for concrete guidance.

## Linking

- Linked back to `[[product]]` as the index, matching `circuit-breaker.md` and `on-call-rotation.md`.
- Added `see also` to `[[circuit-breaker]]` as the closest reliability/db-layer neighbor.
