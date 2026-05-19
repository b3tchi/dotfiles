# Route Decision — idea-implement on us002

## Status check

- **Target story:** `us002` (alias: "filter reports by date range")
- **File:** `docs/notes/us002.md`
- **Actual frontmatter status:** `ready`
- **Required status for `idea-implement`:** `draft`

The skill's checklist step 2 ("Verify status") fails. Per the skill's
own contract:

> The story must already exist — for fresh stories, route to
> `story-write` first. […] Reads `us###` (`story-read`) — the **target
> story** the user named. **Must exist at `status: draft`. Other
> statuses trigger Disambiguation.**

## Disambiguation rule applied

From the `idea-implement` SKILL.md Disambiguation section:

> **`us###` exists at `status: ready`** → nothing to promote; route to
> `infinifu:spec-writing` (or stop if just exploratory).

## Decision

**Stop. Do not run `idea-implement`.** The story is already promoted;
there is nothing for this skill to do. The `## acceptance_criteria`
block is already populated with three testable criteria, so AC
refinement is unnecessary as well.

**Correct next skill:** `infinifu:spec-writing`.

`spec-writing` will mint the companion `sp###` workstream, populate
`## solution`, and lean on the surveyed `cat###` / `adr####` / `ft###`
context that `idea-implement` would have collected if the story had
still been a draft.

## What was NOT written

- No `us002` re-emit (status already `ready`).
- No new `sp###` zettel under `docs/notes/spec/` (that's `spec-writing`'s
  output, not `idea-implement`'s — and only after the user confirms they
  want to proceed past the route handoff).
- No update to `docs/board.md` `## idea` section.
- No new persona, ADR, feature, or category zettels.

## Recommendation to the caller

If the user genuinely wants to push `us002` forward, the next invocation
should be `infinifu:spec-writing` against `us002`. If the user wanted
to *change* `us002`'s already-ready behavior, the correct entry point
is `infinifu:idea-extend` instead.
