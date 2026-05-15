# Decision log — eval-4-hidden-compound-comparison (with_skill)

## Request
> "write a quick note on optimistic locking — specifically how it differs from pessimistic locking for our database access layer. came up when we were reviewing the inventory service and trying to decide which one fits the contention profile."

## Atomicity gate

Restated as a single declarative sentence: **fails.** The request matches the skill's hidden-compound pattern *"X — how it differs from Y"* (SKILL.md, Step 1). Two distinct claims are bundled:

1. Definition / shape of **optimistic locking**.
2. Definition / shape of **pessimistic locking** (necessarily co-defined when describing the contrast).

The comparison itself is a *relationship between the two cards*, not a third atomic claim — it lives in the mutual `see also` wikilinks plus a one-clause framing inside each body ("when conflict rate climbs…compare against [[pessimistic-locking]]"). Adding a third `locking-strategy-tradeoffs` card would have been gold-plating: with only two endpoints, the edge between them carries the comparison.

**Verdict:** split into TWO cards. No third comparison card.

## Provenance ("inventory service" / "contention profile") — where does it go?

The eval framing ("came up when we were reviewing the inventory service") is *context for why the user asked*, not a persisted claim. Per SKILL.md examples ("`X, the kind we ran into during the Y incident` — usually just X with provenance"), this stays as implicit framing — the *contention profile* concept is folded into each body as the deciding axis (conflict rate / hot-row workload) rather than spawned into a separate card. No `inventory-service` zettel is created (no backing context, would dangle without value).

## Type routing

Neither concept matches a typed AKM bucket:

- Not a user story (no persona/want/because).
- Not an ADR (no decision was made — the team was still *evaluating*).
- Not a Feature (not a system capability we provide).
- Not an Implementation (not tied to a specific `us###`).
- Not a Category (taxonomy bucket) or Persona.

**Route:** generic named-slug cards under `docs/notes/` (per SKILL.md `<quick_reference>` last row: "Free-form concept / glossary / external knowledge"). Slugs `optimistic-locking` and `pessimistic-locking` — read naturally inside `[[brackets]]`.

If/when the team decides which one wins for the inventory service, *that* is an ADR (`adr####`) under `[[cat001|infrastructure]]` that links to both of these cards as references. Out of scope for this capture.

## Outbound wikilinks (mandatory ≥ 1 beyond `[[product]]`)

| Card | Outbound links | Rationale |
|------|----------------|-----------|
| `optimistic-locking` | `[[pessimistic-locking]]`, `[[circuit-breaker]]` | Mutual link to its counterpart; secondary link to `[[circuit-breaker]]` because retry storms under high conflict rate are exactly what a circuit breaker mitigates — same failure-protection family. |
| `pessimistic-locking` | `[[optimistic-locking]]`, `[[on-call-rotation]]` | Mutual link to its counterpart; secondary link to `[[on-call-rotation]]` because deadlock tail-latency events are typical paging triggers — operationally adjacent. |

Both secondary links target existing zettels in the vault (`circuit-breaker.md`, `on-call-rotation.md`) — no dangling links introduced.

## Body length

Both cards are one paragraph, ≤ 100 words body each — well under the 300-word / ~30-line gate. No section padding.

## AKM invariants verified

- `[[product]]` in H1: yes (both).
- `Index: [[product]]` footer: yes (both).
- `## see also` with ≥ 1 entry: yes (both).
- Filenames are stable kebab slugs (no dates, owners, ids): yes.
- Generic cards carry `aliases:` + `created:` only — no `status:` (lifecycle states are for typed AKM zettels per SKILL.md `<critical_rules>`).

## Skill checks run (per `<verification_checklist>`)

- [x] Each card's claim restates in one sentence with no "and" / "also".
- [x] Body ≤ 300 words each.
- [x] ≥ 1 outbound wikilink beyond `[[product]]` and `Index:` on each card.
- [x] `[[product]]` in H1, `Index: [[product]]` footer present on both.
- [x] Filenames are stable kebab slugs.
- [x] Generic cards (not typed) — `## see also` present with ≥ 1 entry on both.
- [x] All wikilink targets exist in vault (`product`, `pessimistic-locking` / `optimistic-locking`, `circuit-breaker`, `on-call-rotation`) — no unresolved diagnostics.
