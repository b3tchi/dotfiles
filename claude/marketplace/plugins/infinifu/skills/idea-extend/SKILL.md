---
name: idea-extend
description: Use when the request adjusts behavior the system has already shipped — "us007 should also do X", "us005 is wrong", "the bulk-rejection story needs a reason field", "extend Y to support Z", or any phrasing that modifies an existing user-visible behavior. Routed to from `idea-brainstorming` when the entry type is *us changed adjust implementation*. Captures the problem as `sp###.problem`, surfaces the affected `us###` + `im###`, and frames whether the implementation card needs supersession or just a body refresh after ship.
---

# Idea: Extend (story changed)

## Overview

Specialized brainstormer for the "us changed adjust implementation" entry type. A shipped story needs adjustment. Identify which `us###`, which `im###` it touches, what changes — but no code yet.

**Announce at start:** "Using idea-extend skill to scope a change to an existing story."

<HARD-GATE>
No code, no scaffolding, no bd issues until the design is approved and `sp###` is minted. The next skill is `spec-writing`.
</HARD-GATE>

## AKM hooks

Stage 1 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Entry type: **us changed adjust implementation**.

**Reads:**

- `pn###` (via `persona-read`) — confirm the affected role is still validated; if retired, flag a re-routing question.
- `us###` (via `story-read`) — the existing story being adjusted. Read in full; the AC will likely shift.
- `im###` (via `implementation-read`) — the accepted implementation card. Read `## approach`, `## components`, `## api_surface`, `## data_model` so the proposal is concrete about what changes.
- `cat###` (via `category-read`) — current categories on the `im###`. Adjustments rarely change category, but flag if they would.
- `adr####` (via `adr-read --category <picks>`) — decisions that shaped the original `im###`. Flag any that the adjustment would overturn — overturning an ADR means a new ADR must be filed at spec-retro time.
- `ft###` (via `feature-read`) — features the `im###` consumes. Flag any whose contract the adjustment would widen.

**Writes:**

- `sp###` — new zettel at `docs/notes/spec/sp###.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body: `## solves [[us###]]`, `## problem` describes the delta clearly (what changes in AC, what stays, migration story for already-shipped data).
- `docs/board.md` — append `[[sp###|<title>]]` under `## idea`.
- `us###` — **not yet** mutated by this skill. The AC may shift, but the change lands at `spec-writing` / `spec-refinement` time, not here.
- `im###` — **not yet** mutated. The supersession-vs-refresh question is framed here; the actual flip happens at `work-merge` (status) and `spec-retro` (body rewrite).

## Checklist

1. **Identify the affected `us###`** — confirm with the user or via `story-read` if ambiguous. Read in full.
2. **Find the implementing `im###`** — via `implementation-read` filtered by `solves us###`. If none exists, the story was never specced through the AKM model; flag and re-route or salvage.
3. **Read the implementation** — `## approach`, `## components`, `## api_surface`, `## data_model`. Note what the adjustment touches.
4. **Survey binding ADRs** — `adr-read --category <im###'s categories>`. Flag any the adjustment would overturn.
5. **Survey consumed features** — `feature-read` for the `ft###` list under the `im###`. Flag any whose contract the adjustment would widen.
6. **Ask clarifying questions, one at a time** — what changes in the AC, what stays, what the migration story is for already-shipped data, whether the change is additive or breaking.
7. **Decide: supersession vs body refresh** — does this need a new `im###` (current one superseded), or is it small enough to fold into the existing `im###` via spec-retro at ship time? Capture the decision in `sp###.problem`.
8. **Present design, get approval** — section by section. Cover: AC delta, migration story, ADR conflicts, feature contract impacts, supersession-or-refresh decision.
9. **Mint `sp###`** — `## problem` carries the delta narrative + supersession decision.
10. **Update `docs/board.md`** under `## idea`.
11. **Hand off to `spec-writing`** — the only next step.

## Disambiguation

- **Strict bug** (existing AC violated, no behavior change needed) → re-route to `idea-hotfix`.
- **Behavior change without an existing story** → re-route to `idea-implement`.
- **Adjustment that introduces a new horizontal capability** → re-route to `idea-feature` for the capability, then come back here for the story-side adjustment.

## Key Principles

- **Read the implementation card in full** — adjustments without context produce broken proposals.
- **Flag ADR conflicts early** — overturning an accepted decision is a separate cost the user must own.
- **Be explicit about supersession** — supersede or refresh is the call that shapes the whole downstream chain.

## Integration

**Called by:** `infinifu:idea-brainstorming` (router) when entry type is *us changed*.

**Calls:**

- `infinifu:story-read` / `implementation-read` / `feature-read` / `adr-read` / `category-read` — survey AKM context.
- `infinifu:spec-writing` — the only next step after design approval.
