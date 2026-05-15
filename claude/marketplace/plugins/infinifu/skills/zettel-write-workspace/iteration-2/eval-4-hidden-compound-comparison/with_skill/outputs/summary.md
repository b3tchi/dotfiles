# Summary — eval-4-hidden-compound-comparison (with_skill)

## Cards written

**`optimistic-locking.md`**
Claim: optimistic locking lets concurrent reads proceed and detects conflict at commit via version/row-hash, forcing the loser to retry — cheap when conflicts are rare, inverts when conflict rate climbs into double-digit percent of writes.
Outbound links: `[[pessimistic-locking]]`, `[[circuit-breaker]]`.

**`pessimistic-locking.md`**
Claim: pessimistic locking acquires a row/range lock at read time and holds it until commit, paying conflict cost up front for bounded write-latency tails at the cost of peak throughput — fits hot-row workloads.
Outbound links: `[[optimistic-locking]]`, `[[on-call-rotation]]`.

## Atomicity decision

Hidden compound *"X — how it differs from Y"* detected. Split into two generic concept cards with mutual `see also` links; comparison lives on the edge, not in a third card. Inventory-service framing stays implicit (provenance, not a claim). See `decision-log.md`.

## Skill checks run

Atomicity gate, body length (≤300 words each), ≥1 outbound link beyond `[[product]]`, `[[product]]` H1 + `Index:` footer, stable kebab slugs, no `status:` on generic cards, all wikilink targets resolve in vault.

## Routing

Neither concept matches a typed AKM bucket — routed to generic named-slug cards under `docs/notes/`.
