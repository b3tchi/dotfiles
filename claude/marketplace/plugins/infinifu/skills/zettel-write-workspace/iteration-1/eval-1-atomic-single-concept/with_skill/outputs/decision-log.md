# Decision log — deadlock capture

## Atomicity gate
Restated claim: "A deadlock is a state where two or more threads each hold a resource the other needs, halting all of them."

The phrase "came up in our incident last week on the payment queue" is **capture context**, not a second claim — it explains *why* the user wants the card now, and earns one sentence in the body as provenance. It is not a separate idea about incident response or payment-queue architecture. Single idea — proceeded without splitting.

If the user had wanted the incident itself captured (timeline, blast radius, remediation), that would be a separate `im###` implementation zettel or an ADR, linked from this card. I did not write that card because the user did not ask for it.

## Type detection
A definition of a concurrency concept with no persona, decision, capability, or story shape. No AKM type matches → generic named-slug card under `docs/notes/`.

## Slug choice
`deadlock` — reads cleanly as `[[deadlock]]`, single noun, no qualifier needed (no naming collision with existing zettels in the vault).

## Link choices
- `[[circuit-breaker]]` — user explicitly requested. Justified: circuit breakers are a *response* pattern to the kind of cascading wedge a deadlock produces downstream.
- `[[on-call-rotation]]` — user said "maybe". Kept it: deadlocks are an incident-page driver, so the link is real, not decorative.

## No-confirmation calls made
- Did not ask the user to confirm the split (would have been a no-op — single idea).
- Did not ask the user to confirm slug `deadlock` vs alternatives like `deadlock-concurrency`.
- Did not propose a separate `payment-queue-incident` card; the user did not request it and inventing one would have padded the graph.
