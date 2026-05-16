---
name: idea-implement
description: "You MUST use this when the request asks the system to gain a new user-facing behavior it doesn't have yet — 'add X', 'build Y', 'users should be able to Z', 'we need a feature where the analyst can …', or any phrasing that describes a fresh story from a persona's perspective and no existing `us###` covers it. Direct entry point for AKM lifecycle stage 1, *us implement* entry type. Captures a fresh user story (`us###`) and emits the initial spec (`sp###`) with `## problem` populated, after surveying categories / ADRs / features so the proposal is grounded in real zettel ids. Loads shared brainstorming basics from `infinifu:idea-brainstorming`."
---

# Idea: Implement (new story)

## Overview

Direct entry point for the "us implement" entry type of the AKM lifecycle. The system is gaining a new behavior. Walk the user through persona / want / because / acceptance criteria; ground the proposal in existing categories / ADRs / features; capture a fresh `us###` and a new `sp###` with `## problem` populated.

**Announce at start:** "Using idea-implement skill to capture a new story."

**Shared basics.** Process (context exploration, hard gate, question cadence, design approval, spec-writing handoff) lives in `infinifu:idea-brainstorming`. Load it before walking the checklist below.

## AKM hooks

Stage 1 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Entry type: **us implement**.

**Reads:**

- `pn###` (`persona-read`) — existing personas. If the role driving the new behavior matches one, use it; if not, mint via `persona-write` before continuing.
- `us###` (`story-read` / `story-find`) — existing stories. Surface overlaps; if one covers the same surface, re-route to `idea-extend`.
- `cat###` (`category-read`) — taxonomy buckets the new behavior touches. Pick from existing; never invent.
- `adr####` (`adr-read --category <picks>`) — decisions binding the picked categories. Surface what the future solution will inherit.
- `ft###` (`feature-read`) — capabilities the future solution might consume. List candidates; binding choice happens at `spec-writing`.

**Writes:**

- `us###` — new story draft via `story-write` (status `draft` → `ready` once `## acceptance_criteria` are testable).
- `sp###` — new zettel at `docs/notes/spec/sp###.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body: `## solves [[us###]]` + `## problem` populated; H1 carries proposed `[[cat###]]` picks.
- `docs/board.md` — append `[[sp###|<title>]]` under `## idea`.

## Entry-specific checklist

1. **Persona survey.** If the driving role isn't an existing `pn###`, mint via `persona-write` first.
2. **Story-overlap check.** `story-find` on the topic. Strong overlap → re-route to `idea-extend` and stop.
3. **Categorize.** Survey via `category-read`; pick the buckets that fit.
4. **Survey ADRs** under those categories via `adr-read`. Capture binding decisions; flag any conflicts.
5. **Survey features** via `feature-read`. List candidate consumers without committing to consumption.
6. **Mint `us###`** via `story-write` once AC are testable.
7. **Mint `sp###`** with `## problem` populated; reference surveyed ADRs and feature candidates.
8. **Update `docs/board.md`** under `## idea`.

Walk the shared process around this checklist (load `idea-brainstorming` for steps 1-5 cadence and presentation).

## Disambiguation

- **Existing `us###` covers this surface** → re-route to `idea-extend`.
- **Horizontal capability with multiple potential consumers, no single story drives it** → re-route to `idea-feature`.
- **Production bug** → re-route to `idea-hotfix`.

## Key Principles (entry-specific)

- **Persona before story.** No story without a clear role to anchor it.
- **AC testable before `ready`.** Vague criteria block the whole downstream chain.
- **Feature consumption is a candidacy here, not a commitment.** Spec-writing locks consumption.

## Integration

**Calls:**

- `infinifu:persona-read` / `persona-write` — survey or mint personas.
- `infinifu:story-read` / `story-find` — overlap check.
- `infinifu:story-write` — emit new `us###`.
- `infinifu:category-read` / `adr-read` / `feature-read` — AKM context survey.
- `infinifu:idea-brainstorming` — shared process basics (loaded as reference, not invoked as a router).
- `infinifu:spec-writing` — the only next step after design approval.
