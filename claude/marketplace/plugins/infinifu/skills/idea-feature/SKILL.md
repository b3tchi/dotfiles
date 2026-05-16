---
name: idea-feature
description: "You MUST use this when the request adds a horizontal, reusable capability the system will provide once and many implementations will consume — 'we need an audit-log service', 'add a shared rate-limit feature', 'register a notifications building block', 'we should have a generic file-upload feature', or any phrasing that describes a building block decoupled from a single user story. Direct entry point for AKM lifecycle stage 1, *feature add* entry type. Captures the problem as `sp###.problem` with the intent to mint a new `ft###` at the spec stage, after surveying existing features so duplicates are caught and consumers are listed concretely. Loads shared brainstorming basics from `infinifu:idea-brainstorming`."
---

# Idea: Feature (new horizontal capability)

## Overview

Direct entry point for the "feature add" entry type. A new horizontal capability is being proposed — one the system provides once and many implementations consume. No single user story drives it; it's a building block.

**Announce at start:** "Using idea-feature skill to scope a new horizontal capability."

**Shared basics.** Process (context exploration, hard gate, question cadence, design approval, spec-writing handoff) lives in `infinifu:idea-brainstorming`. Load it before walking the checklist below.

## AKM hooks

Stage 1 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Entry type: **feature add**.

**Reads:**

- `ft###` (`feature-read`) — existing features. Mandatory dedup check. Similar feature exists → re-route to `idea-extend` on that feature.
- `us###` (`story-read` / `story-find`) — likely consumers. A capability with zero plausible consumers is suspicious; surface concrete consumer stories before proceeding.
- `im###` (`implementation-read`) — implementations that today implement similar logic ad-hoc. Migration targets.
- `cat###` (`category-read`) — taxonomy buckets the capability lives in. Pick from existing; never invent.
- `adr####` (`adr-read --category <picks>`) — decisions that constrain the capability (retention, secrets, latency budgets, allowed dependencies).

**Writes:**

- `sp###` — new zettel at `docs/notes/spec/sp###.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body: `## problem` describes capability boundary, consumers, constraints, and the intent to mint a new `ft###` at spec-writing time.
- `docs/board.md` — append `[[sp###|<title>]]` under `## idea`.

The `ft###` is **not** minted by this skill — the capability boundary is still under discussion. Minting at `spec-writing` time avoids a half-formed feature ending up in the registry.

## Entry-specific checklist

1. **Dedup check.** `feature-read` filtered by keyword. Close match → re-route to `idea-extend` on that `ft###` and stop.
2. **Identify consumers.** `story-find` and `implementation-read`. Zero or one plausible consumer is a red flag — features are reusable by definition.
3. **Inventory ad-hoc implementations.** `implementation-read` filtered by keyword. List migration candidates.
4. **Categorize.** Survey via `category-read`. Horizontal capabilities typically live in 1-2 categories.
5. **Survey binding ADRs** under the picked categories via `adr-read`.
6. **Migration sketch.** One-line note per ad-hoc `im###` on migration cost.
7. **Mint `sp###`** with `## problem` covering capability + consumers + constraints + migration intent.
8. **Update `docs/board.md`** under `## idea`.

Walk the shared process around this checklist.

## Disambiguation

- **Capability that serves exactly one story** → re-route to `idea-implement` (it's `im###` glue, not `ft###`).
- **Modification to an existing feature** → re-route to `idea-extend` framed against the `ft###`.
- **Production-broken capability** → re-route to `idea-hotfix`.

## Key Principles (entry-specific)

- **A feature with one consumer is not a feature.** Features are reusable by definition. One-consumer "features" are `im###` glue in disguise.
- **Constraints inherit from categories.** ADRs under the picked categories bind the feature automatically.
- **Migration is part of the proposal.** Listing the ad-hoc `im###` migration targets is what proves the feature pays for itself.

## Integration

**Calls:**

- `infinifu:feature-read` / `implementation-read` / `story-find` / `category-read` / `adr-read` — AKM context survey.
- `infinifu:idea-brainstorming` — shared process basics.
- `infinifu:spec-writing` — the only next step after design approval; it mints `ft###`.
