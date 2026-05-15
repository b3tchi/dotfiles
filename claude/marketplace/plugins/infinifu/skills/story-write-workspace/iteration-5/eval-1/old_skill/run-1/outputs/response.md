# Story Captured

Used `story-write` skill to capture the warehouse picker request.

## Story ID
`2605-001`

## Connextra Sentence
As a **warehouse picker**, I want **to mark a request as picked once items are pulled from inventory**, because **that signals it's ready for handoff**.

## Acceptance Criteria (derived — flagged)
The user did not supply acceptance criteria, so 4 baseline criteria were derived covering entry point, success path, state guard, and error case:

- Picker can transition a request to "picked" status from the request detail view
- Marking as picked is only allowed when the request is in an active/in-progress state (not already picked, cancelled, or handed off)
- Once marked picked, the request appears in the handoff-ready queue and is timestamped with the pick completion time
- Attempting to mark an already-picked request as picked returns a clear error and does not change state

## Tags (derived — flagged)
The user did not specify tags. Since the backlog was empty (fresh `product/stories.yaml`), suggested tags drawn from the system area:

- `warehouse` — operational area
- `fulfillment` — workflow domain
- `request-status` — state-transition feature

## Storage Path
`product/stories.yaml` (created — file did not previously exist)

## Status
`draft`

## Flags for User Review
1. Acceptance criteria were derived, not user-supplied — please confirm or revise.
2. Tags were derived from system area, not user-supplied — please confirm or revise.

Anything to revise?
