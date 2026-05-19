# Decision log — eval-2 compound split

## Input
> capture today's learnings from the kanban workshop: WIP limits prevent overload by capping in-flight work, and pull-based systems generally beat push-based because they self-regulate to capacity. both fit our team but the WIP limit one is the one I keep coming back to.

## Atomicity gate

Surface-compound signal: explicit "and" joining two distinct claims with distinct subjects ("WIP limits" vs "pull-based systems") and distinct verbs ("prevent overload" vs "beat push-based"). Not a comparison hidden in one claim — two independent kanban principles that happen to reinforce each other.

**Decision: split into 2 zettels.** Did not ask for confirmation per the no-clarifying-questions instruction; the compound is unambiguous.

| Claim | One-sentence restatement | Card |
|-------|--------------------------|------|
| A | WIP limits cap in-flight work so overload becomes a visible stall instead of hidden queueing. | `wip-limits.md` |
| B | Pull-based flow lets downstream capacity drive upstream work, so the system self-regulates to actual throughput. | `pull-based-flow.md` |

The user's emphasis ("the WIP limit one is the one I keep coming back to") is provenance / preference, not a third claim — recorded here, not promoted to a card.

## Type routing

Neither claim is a story (`us`), persona (`pn`), feature (`ft`), implementation (`im`), ADR (`adr`), or category (`cat`). Both are reusable principle cards / external-knowledge concepts → generic named-slug cards per `zettel-write` Step 3.

## Slug choices

- `wip-limits` — reads cleanly as `[[wip-limits]]`; matches how the concept is named in practice (lowercase initialism is conventional).
- `pull-based-flow` — preferred over `pull-vs-push` (which would imply a comparison card) and over `pull-system` (less specific). Reads well as `[[pull-based-flow]]`.

## Wikilinks chosen

Each card carries `[[product]]` in H1 + `Index: [[product]]` footer (AKM invariant) plus at least one outbound link beyond those:

- `wip-limits.md` → `[[pull-based-flow]]` (sibling principle, written in same batch) and `[[on-call-rotation]]` (existing vault zettel — capacity / overload framing applies to rotations).
- `pull-based-flow.md` → `[[wip-limits]]` (sibling) and `[[circuit-breaker]]` (existing vault zettel — fail-fast / capacity-protection sibling).

Mutual link between the two new cards is the canonical compound-split scaffolding (split, then connect with wikilinks, not section headings).

## Post-write audit

| Check | wip-limits | pull-based-flow |
|-------|------------|-----------------|
| Single idea (1-sentence restate, no "and") | pass | pass |
| Body ≤ 300 words / ~30 lines | pass (~80 words) | pass (~95 words) |
| ≥ 1 outbound link beyond `[[product]]` + Index | pass (2) | pass (2) |
| `[[product]]` in H1 + `Index: [[product]]` footer | pass | pass |
| Filename = stable kebab slug, no date/owner | pass | pass |
| `## see also` present (generic card requirement) | pass | pass |

Both pass. No rejection or rewrite.
