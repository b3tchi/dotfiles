---
name: idea-implement
description: "You MUST use this when the user wants to move an existing draft user story toward execution — 'implement us007', 'let's work on the rotate-credentials story', 'us003 is ready, scope it for spec-writing', 'we have a draft for the analyst share-link story, let's prepare it', or any phrasing that names (by id or alias) a `us###` that already exists at `status: draft` and needs promotion to `ready` plus a companion `sp###`. Direct entry point for AKM lifecycle stage 1, *us implement* entry type. Promotes the draft story to `ready` (filling AC if testable, blocking if not) and emits the initial spec (`sp###`) with `## problem` populated and surveyed `ft/cat/adr` ids cited as wikilinks. The story must already exist — for fresh stories, route to `story-write` first. Loads shared brainstorming basics from `infinifu:idea-brainstorming`."
---

# Idea: Implement (existing draft story → ready + sp###)

## Overview

Direct entry point for the "us implement" entry type. An existing `us###` is in `status: draft` and the user wants to move it forward: refine the acceptance criteria until they are testable, promote `status: draft → ready`, and emit a companion `sp###` carrying `## problem` so spec-writing can pick it up.

**This skill does NOT create user stories from scratch.** The lifecycle reads `us###` here, not writes a new one. Fresh story ideas go through `story-write` first; come back to `idea-implement` once the draft exists.

**Announce at start:** "Using idea-implement skill to promote an existing draft story."

**Shared basics.** Process (context exploration, hard gate, question cadence, design approval, spec-writing handoff) lives in `infinifu:idea-brainstorming`. Load it before walking the checklist below.

## AKM hooks

Stage 1 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Entry type: **us implement**.

**Reads** (per lifecycle contract — `pn`, `us`, `cat`, `adr`, `ft`):

- `us###` (`story-read`) — the **target story** the user named. Must exist at `status: draft`. Other statuses trigger Disambiguation.
- `pn###` (`persona-read`) — the persona referenced by the story's `## role`. If missing, mint via `persona-write` before continuing.
- `cat###` (`category-read`) — taxonomy buckets the story touches. Pick from existing; never invent.
- `adr####` (`adr-read --category <picks>`) — decisions binding the picked categories. Surface what spec-writing will inherit.
- `ft###` (`feature-read`) — capabilities spec-writing might consume. List candidates; binding choice happens at `spec-writing`.

**Writes:**

- `us###` — same file, `status: draft → ready`. Fill `## acceptance_criteria` only if you have testable criteria from the user; otherwise hold the gate.
- `sp###` — new zettel at `docs/notes/spec/sp###.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body: `## solves [[us###]]` + `## problem` populated. **Every surveyed id that's relevant must appear in `## problem` as a wikilink** — `[[us###]]` for the source story, `[[pn###]]` for the persona, `[[cat###]]` for category picks, `[[ft###]]` for candidate consumers, `[[adr####]]` for binding decisions. Narrative without ids fails the lifecycle contract.
- `docs/board.md` — append `[[sp###|<title>]]` under `## idea`.

## Entry-specific checklist

1. **Identify target story.** User must name a `us###` (by id or alias). If not named, ask. Verify `docs/notes/us###.md` exists.
2. **Verify status.** Read frontmatter `status`. Apply Disambiguation if it isn't `draft`.
3. **Read the story.** Confirm `## role`, `## want`, `## because` are populated. Missing pieces surface as clarifying questions; do not invent answers.
4. **Persona check.** Resolve `## role: [[pn###]]` to the persona file. If missing, mint via `persona-write` before continuing (sub-loop).
5. **AC check.** If `## acceptance_criteria` is empty or vague, this is the design-approval question — ask the user for testable criteria. Do NOT promote `status: ready` with untestable AC; doing so blocks the whole downstream chain.
6. **Categorize.** Survey via `category-read`. Pick the buckets the story touches.
7. **Survey ADRs** under those categories via `adr-read`. Capture binding decisions.
8. **Survey features** via `feature-read`. List candidate consumers without committing to consumption.
9. **Promote `us###`** `draft → ready` once AC are testable. Re-emit via `story-write` (same id; story content lives in the same file).
10. **Mint `sp###`** at `docs/notes/spec/sp###.md` with `## solves [[us###]]` + `## problem`. **Reference discipline:** every relevant surveyed id lands in `## problem` as a wikilink — `[[us###]]` source, `[[pn###]]` persona, `[[cat###]]` picks, `[[ft###]]` candidates, `[[adr####]]` binders. Prose without ids does not satisfy.
11. **Update `docs/board.md`** under `## idea` with the new `[[sp###]]`.

Walk the shared process around this checklist (load `idea-brainstorming` for cadence + gate basics).

## Disambiguation

- **`us###` does not exist (file missing)** → route to `infinifu:story-write` first; resume here once draft is in place.
- **`us###` exists at `status: ready`** → nothing to promote; route to `infinifu:spec-writing` (or stop if just exploratory).
- **`us###` exists at `status: in_progress`** → bd epic already exists; route to ongoing work (`work-do`).
- **`us###` exists at `status: done`** → can't promote shipped story; if user wants a change, route to `infinifu:idea-extend` against that story.
- **`us###` exists at `status: dropped` / `retired`** → block; surface the dropped-status note and ask the user whether to revive (separate decision) or close the request.
- **User describes a fresh ask with no `us###` named** → route to `infinifu:story-write` first.
- **Request is a horizontal, multi-consumer capability** → route to `infinifu:idea-feature`.
- **Request is a production-broken behavior** → route to `infinifu:idea-hotfix`.

## Key Principles (entry-specific)

- **Story exists first, then idea-implement.** This skill consumes drafts, never produces them. Forcing it to "create the story while we're at it" muddles the lifecycle and is why `story-write` lives upstream.
- **AC testable before `ready`.** Vague criteria block downstream — the gate exists exactly to hold that line. Promotion without testable AC is a known anti-pattern; spec-writing will fail to plan against shifting targets.
- **Persona before promotion.** A story whose `## role` doesn't resolve to a real `pn###` cannot be `ready`. Mint the persona first; rebound here.
- **Reference discipline.** Surveyed ids land as wikilinks in `## problem` — that's how spec-writing, spec-refinement, and the moxide LSP traverse the graph downstream. Prose-only descriptions break the chain.
- **Feature consumption is candidacy, not commitment.** Listing `[[ft###]]` candidates in `## problem` is a survey output; binding consumption happens at `spec-writing`.

## Integration

**Calls:**

- `infinifu:story-read` — fetch the target `us###`; verify status + body.
- `infinifu:persona-read` / `persona-write` — survey or mint personas (sub-loop if missing).
- `infinifu:story-write` — re-emit the `us###` to flip `status: draft → ready` (same id, same file).
- `infinifu:category-read` / `adr-read` / `feature-read` — AKM context survey.
- `infinifu:idea-brainstorming` — shared process basics (reference, not invoked as a router).
- `infinifu:spec-writing` — the only next step after the sp### lands and the user approves.
