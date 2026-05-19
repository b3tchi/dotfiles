# story-write run-1 summary

## ID assigned

- **Story id:** `us015` (existing max was `us014`, gap-preserving so next is 15)
- **File:** `docs/notes/us015.md`
- **Status:** `draft`
- **Created:** `2026-05-14`

## Persona handling

The user said "the warehouse picker". No existing persona matched (`pn001` = requestor, `pn002` = approver). In auto mode, the defensible call was to **create a new persona** rather than miscast the role onto requestor/approver, since "picker" is a distinct actor with distinct workflow.

- **New persona id:** `pn003`
- **Canonical alias:** `picker`
- **File:** `docs/notes/pn003.md`
- **Status:** `draft` (per skill's minimal persona conventions)
- **Role wikilink in story:** `[[pn003|picker]]`

## Connextra sentence

As a **picker**, I want to **mark a request as picked once items are pulled from inventory**, because **that signals the request is ready for handoff**.

## Acceptance criteria — disclosure

The user gave zero acceptance criteria. Skill rule: in non-interactive mode, derive 2-4 baseline criteria and flag them explicitly.

**Derived (not user-provided):**

- picker can transition an approved request to a "picked" state from the fulfillment view (success path / entry point)
- only requests in the approved state can be marked as picked (boundary — links to existing approver flow)
- picked timestamp and picker identity are recorded on the request (audit trail)
- requests marked as picked appear in a "ready for handoff" queue (motivation directly from the `because` clause)

User should confirm or revise these — none came from their message.

## Tags — disclosure

The user did not specify tags. Auto-mode derivation (without invoking `tag-manage`):

- `[[picker-flow]]` — parallels the existing `[[requestor-flow]]` convention seen in `us014`
- `[[fulfillment]]` — domain-area tag for the pick/pack/handoff stage

Both are derived, not user-provided. They may dangle (no backing zettels) — acceptable per skill.

## Hub update

`docs/product.md` updated: added a new `### [[pn003|picker]]` section under `## Stories` with the `[[us015|...]]` link.

## Files written / modified

- `docs/notes/us015.md` (new)
- `docs/notes/pn003.md` (new)
- `docs/product.md` (appended picker section)
