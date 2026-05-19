# Decision log — eval-1 (atomic single concept, with_skill)

## Decisions made without user confirmation

### 1. Atomicity gate — passed without split
**Restated claim:** "Deadlock is the state where two or more threads each hold a resource the other needs and none will release until they get the other's, so none progresses."

**Hidden-compound check.** The request mentions (a) the definition, (b) provenance ("came up in our incident last week on the payment queue"), and (c) two requested links (`[[circuit-breaker]]`, `[[on-call-rotation]]`). Per skill guidance, "X, the kind we ran into during the Y incident" is usually still just X with provenance — and the user explicitly framed the incident as where it "came up", not as a separate idea to persist. The incident detail is folded into the body as a concrete example, not as a second claim. The links are wikilinks, not separate cards. Single card. ✓

Skill says "When in doubt, propose the split — the user can tell you to merge." Per the no-clarifying-questions directive, I made the reasonable call: not in doubt. Atomic.

### 2. Type routing — generic named-slug card
Not a story (no persona/want/because), not an ADR (no decision being recorded), not a feature/implementation/persona/category. It is a free-form computer-science / concurrency concept the user wants to remember. Routes to `docs/notes/<slug>.md` per the skill's generic card path.

### 3. Slug choice — `deadlock`
Reads cleanly as `[[deadlock]]`. Single word, lowercase, no date/owner/incident-context baked into the filename (per skill: "context goes in aliases or body").

### 4. Body shape — one paragraph
Skill says: "If a section starts feeling necessary, the card is already two ideas." Definition + escape hatches (lock ordering, timeouts, design-out) + the incident as concrete instantiation all fit in one paragraph. No `## context` / `## mitigations` headings — those would be the seam of a future split.

### 5. Provenance handling
The payment-queue incident is referenced as a *concrete instantiation* in the last sentence ("Surfaced in the payment-queue incident as …") rather than as a separate `## incident` section. This keeps the card atomic — the example is in service of the claim, not a second claim. If the user later wants the incident itself as a card, that's a separate `payment-queue-deadlock-incident-2026-05` zettel that would link back to `[[deadlock]]`.

### 6. Outbound links — kept to the two the user asked for
Both `[[circuit-breaker]]` and `[[on-call-rotation]]` exist in the vault (verified by reading them). They are the user's requested connections — both are reasonable: circuit-breaker is the canonical pattern for "fail fast instead of waiting forever on a held resource", and on-call-rotation is the human-side counterpart (who pages when deadlocks deadlock production). No fabricated extra links.
