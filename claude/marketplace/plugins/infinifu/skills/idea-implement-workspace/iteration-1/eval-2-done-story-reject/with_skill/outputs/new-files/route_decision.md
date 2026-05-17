# Route decision — idea-implement on us001

**Verdict:** REJECT. Do not run `idea-implement`. Re-route required.

## Target

- Story: `[[us001|view dashboard of recent reports]]`
- File: `docs/notes/us001.md`
- Frontmatter `status:` **`done`**
- Persona: `[[pn001|analyst]]`
- Implementation already shipped: `[[im001|reports dashboard via reports-service UI]]` (`status: accepted`)

## Why idea-implement is wrong here

`idea-implement` consumes drafts and promotes them `draft → ready`. From the skill's Disambiguation table:

> **`us###` exists at `status: done`** → can't promote shipped story; if user wants a change, route to `infinifu:idea-extend` against that story.

`us001` is already shipped — there is nothing to promote. Forcing a `draft → ready` re-emit would corrupt a `done` story (status regression), violate AKM append-only spirit on the linked `accepted` `im001`, and skip the entry-type gate the lifecycle relies on.

The Entry-specific checklist step 2 ("Verify status") trips the gate at the first read.

## Re-route

- **If the user actually wants to change behavior of the shipped feature** → `infinifu:idea-extend` against `us001`. That entry type frames the problem as `sp###.problem`, surfaces the existing `im001`, and decides whether `im001` needs supersession or just a body refresh after the next ship.
- **If the user wants a brand-new related story** (e.g. a different dashboard for a different persona) → `infinifu:story-write` first, then come back to `idea-implement` once a fresh `us###` exists at `status: draft`.
- **If the user just wanted to see the story** → `infinifu:story-read us001`.

## Actions taken in the sandbox

None. No `us###`, `sp###`, `board.md`, `product.md`, or `im###` files modified. This file (`route_decision.md`) is the only artifact written, recording the reject + re-route rationale.
