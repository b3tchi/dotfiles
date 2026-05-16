---
name: idea-feature
description: Use when the request adds a horizontal, reusable capability the system will provide once and many implementations will consume — "we need an audit-log service", "add a shared rate-limit feature", "register a notifications building block", "we should have a generic file-upload feature". Routed to from `idea-brainstorming` when the entry type is *feature add*. Captures the problem as `sp###.problem` with the intent to mint a new `ft###` at the spec stage, after surveying existing features so duplicates are caught and consumers are listed concretely.
---

# Idea: Feature (new horizontal capability)

## Overview

Specialized brainstormer for the "feature add" entry type. A new horizontal capability is being proposed — one the system provides once and many implementations consume. No single user story drives it; it is a building block.

**Announce at start:** "Using idea-feature skill to scope a new horizontal capability."

<HARD-GATE>
No code, no `ft###` minted yet (the `ft###` lands at `spec-writing` time when the API surface is locked), no scaffolding until the design is approved and `sp###` is minted.
</HARD-GATE>

## AKM hooks

Stage 1 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Entry type: **feature add**.

**Reads:**

- `ft###` (via `feature-read`) — existing features. Mandatory dedup check before proposing anything. If a similar feature exists, re-route to `idea-extend` on that feature.
- `us###` (via `story-read` / `story-find`) — likely consumers. A capability with zero plausible consumers is suspicious; surface concrete consumer stories before proceeding.
- `im###` (via `implementation-read`) — implementations that today implement similar logic ad-hoc. These are the migration targets for the new feature — list them.
- `cat###` (via `category-read`) — taxonomy buckets the capability lives in. Pick from existing; do not invent.
- `adr####` (via `adr-read --category <picks>`) — decisions that constrain the capability (retention, secrets, latency budgets, allowed dependencies).

**Writes:**

- `sp###` — new zettel at `docs/notes/spec/sp###.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body: `## problem` describes the capability boundary, consumers, constraints, and the intent to mint a new `ft###` at spec-writing time.
- `docs/board.md` — append `[[sp###|<title>]]` under `## idea`.
- `ft###` — **not** minted by this skill. The capability boundary is still under discussion; minting at `spec-writing` time avoids a half-formed feature ending up in the registry.

## Checklist

1. **Dedup check** — `feature-read` filtered by keyword. If a close match exists, this might be `idea-extend` on that feature; re-route and stop.
2. **Identify consumers** — which `us###` / `im###` will plausibly consume this? Surface via `story-find` and `implementation-read --consumes <keyword>`. A capability with zero or one consumer is a red flag — features are reusable by definition.
3. **Inventory ad-hoc implementations** — `implementation-read` filtered by keyword. List the `im###` that today do this work ad-hoc; these are migration candidates.
4. **Categorize** — propose `[[cat###]]` buckets. Survey via `category-read`. A horizontal capability typically lives in 1-2 categories (e.g. an audit-log might be `cat002 (data)` + `cat003 (security)`).
5. **Survey binding ADRs** — under the picked categories. Note retention / security / latency / dependency constraints. The new feature will inherit them.
6. **Ask clarifying questions, one at a time** — capability boundary, who consumes, what the API surface roughly looks like, what state the feature owns, what state belongs to consumers.
7. **Propose 2-3 capability shapes** — with trade-offs (e.g. push-vs-pull, synchronous-vs-async, owned-state-vs-stateless).
8. **Migration sketch** — for each ad-hoc `im###`, one-line note on the migration cost.
9. **Present design, get approval** — section by section. Cover: providing, API surface (rough), data model (rough), consumers, constraints, migration story.
10. **Mint `sp###`** — `## problem` describes capability + consumers + constraints + migration intent. Note: this skill does NOT mint `ft###`.
11. **Update `docs/board.md`** under `## idea`.
12. **Hand off to `spec-writing`** — it will mint the `ft###` and lock the API surface.

## Disambiguation

- **Capability that serves exactly one story** → re-route to `idea-implement` (story-specific glue, not a feature).
- **Modification to an existing feature** → re-route to `idea-extend` framed against the `ft###` instead of a `us###`.
- **Production-broken capability** → re-route to `idea-hotfix`.

## Key Principles

- **A feature with one consumer is not a feature** — features are reusable by definition. If only one story consumes it, it's `im###` glue, not `ft###`.
- **Constraints inherit from categories** — ADRs under the picked categories bind the feature automatically. Surface them now.
- **Migration is part of the proposal** — listing the ad-hoc `im###` migration targets is what proves the feature pays for itself.

## Integration

**Called by:** `infinifu:idea-brainstorming` (router) when entry type is *feature add*.

**Calls:**

- `infinifu:feature-read` / `implementation-read` / `story-find` / `category-read` / `adr-read` — survey AKM context.
- `infinifu:spec-writing` — the only next step after design approval; it mints `ft###`.
