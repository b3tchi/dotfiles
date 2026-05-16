---
name: idea-implement
description: Use when the request asks the system to gain a new user-facing behavior it doesn't have yet — "add X", "build Y", "users should be able to Z", "we need a feature where the analyst can …", or any phrasing that describes a fresh story from a persona's perspective. Routed to from `idea-brainstorming` when the entry type is *us implement*. Captures a fresh user story (`us###`) and emits the initial spec (`sp###`) with the `## problem` section populated, after surveying categories / ADRs / features so the proposal is grounded in what already exists.
---

# Idea: Implement (new story)

## Overview

Specialized brainstormer for the "us implement" entry type of the AKM lifecycle. The system is getting a new behavior. Walk the user through persona / want / because / acceptance criteria, ground the proposal in existing categories / ADRs / features, then capture a fresh `us###` and a new `sp###` with `## problem` populated.

**Announce at start:** "Using idea-implement skill to capture a new story."

<HARD-GATE>
No code, no scaffolding, no bd issues until the design is approved and `sp###` is minted. The next skill in the chain is `spec-writing`, never an implementation skill.
</HARD-GATE>

## AKM hooks

Stage 1 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Entry type: **us implement**.

**Reads:**

- `pn###` (via `persona-read`) — existing personas. If the role driving the new behavior matches one (by alias / name / summary), use it; if not, propose a fresh `pn###` via `persona-write` before continuing.
- `us###` (via `story-read` / `story-find`) — existing stories. Surface anything that overlaps so you don't duplicate. If a strong overlap exists, re-route to `idea-extend`.
- `cat###` (via `category-read`) — taxonomy buckets the new behavior touches. Pick from existing ones; do not invent.
- `adr####` (via `adr-read --category <picks>`) — decisions binding the picked categories. Surface what the future solution will inherit.
- `ft###` (via `feature-read`) — reusable capabilities the future solution might consume. List candidates; binding choice happens later in `spec-writing`.

**Writes:**

- `us###` — new story draft via `story-write` (status `draft`). Flip to `ready` once `## acceptance_criteria` are testable.
- `sp###` — new zettel at `docs/notes/spec/sp###.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body has `## problem` populated and H1 carries the proposed `[[cat###]]` picks. Later sections (`## solution`, `## plan`, `## tasks`) land in stages 2-4.
- `docs/board.md` — append `[[sp###|<title>]]` under `## idea`.

## Checklist

1. **Explore project context** — read README, recent commits, relevant `src/` paths so the design is grounded in the actual codebase.
2. **Persona survey** — `persona-read`. If the driving role matches an existing `pn###`, use it. If not and a real role is forming, mint via `persona-write` first.
3. **Story-overlap check** — `story-find` on the topic. If an existing story already covers this surface, propose re-routing to `idea-extend` and stop.
4. **Categorize** — propose which `[[cat###]]` buckets fit. Survey via `category-read` so picks are real.
5. **Survey ADRs under those categories** — `adr-read --category <pick>`. Capture binding decisions; flag any conflicts the new behavior would create.
6. **Survey features** — `feature-read` for capabilities the future solution might consume. List candidates with a one-line note each; do not commit to consumption (spec-writing locks that).
7. **Ask clarifying questions, one at a time** — persona / want / because / success criteria. Multiple-choice preferred. Cap at one question per message.
8. **Propose 2-3 design approaches** — with trade-offs and your recommended option.
9. **Present design, get approval** — section by section, scaled to complexity.
10. **Mint `us###`** — via `story-write`. Acceptance criteria must be testable before flipping to `ready`.
11. **Mint `sp###`** — at `docs/notes/spec/sp###.md`. Body: `## solves [[us###]]`, `## problem` populated; categories in H1; surveyed ADRs and feature candidates referenced in the problem narrative or a brief notes section.
12. **Update `docs/board.md`** — append `[[sp###|<title>]]` under `## idea`.
13. **Hand off to `spec-writing`** — the only next step. Do not invoke implementation skills.

## Process

**Understanding the idea:**

- Check the current project state first (files, docs, recent commits).
- Ask questions one at a time; multiple-choice preferred but open-ended is fine.
- Focus on persona / want / because / acceptance criteria.

**Grounding in AKM:**

- After the high-level shape is clear, survey categories / ADRs / features before proposing approaches. This is what keeps the proposal honest — every "we could use X" is anchored to a real zettel id, not invented.

**Exploring approaches:**

- Propose 2-3 with trade-offs and your recommendation. Lead with the recommended option.

**Presenting the design:**

- Section by section, scaled to complexity. Confirm after each section.
- Cover: persona, want, because, acceptance criteria, categories, ADR constraints, feature candidates.

## Key Principles

- **One question at a time** — don't overwhelm.
- **Multiple-choice preferred** — easier to answer when options are clear.
- **Survey before proposing** — never invent category/ADR/feature ids.
- **YAGNI ruthlessly** — trim non-essential scope from the story.
- **Incremental validation** — get approval per section before moving on.

## Integration

**Called by:** `infinifu:idea-brainstorming` (router) when entry type is *us implement*.

**Calls:**

- `infinifu:persona-read` / `persona-write` — survey or mint personas.
- `infinifu:story-read` / `story-find` — overlap check.
- `infinifu:story-write` — emit the new `us###`.
- `infinifu:category-read` / `adr-read` / `feature-read` — survey AKM context.
- `infinifu:spec-writing` — the only next step after design approval.
