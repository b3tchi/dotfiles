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

**Reads** (per lifecycle contract — `ft`, `im`, `cat`, `adr`; no `us` reads at this stage):

- `ft###` (`feature-read`) — existing features. Mandatory dedup check (stage-1 goal: mitigate duplication). Similar feature exists → re-route to `idea-extend` on that feature.
- `im###` (`implementation-read`) — implementations that today carry similar logic ad-hoc. Both **consumers** (via each im###'s `solves`/`features` back-links) and **migration targets** come from here. `us###` is reached transitively through `im###` — direct story-find is out of scope for this skill.
- `cat###` (`category-read`) — taxonomy buckets the capability lives in. Pick from existing; never invent.
- `adr####` (`adr-read --category <picks>`) — decisions that constrain the capability (retention, secrets, latency budgets, allowed dependencies).

**Writes:**

- `sp###` — new zettel at `docs/notes/spec/sp###.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body: `## problem` describes capability boundary, consumers, constraints, and the intent to mint a new `ft###` at spec-writing time. **Every surveyed id that is relevant must appear in `## problem` as a wikilink** — `[[ft###]]` for dedup-considered features, `[[im###]]` for consumer/migration targets, `[[cat###]]` for category picks, `[[adr####]]` for binding or conflicting decisions. Narrative alone does not satisfy the lifecycle contract.
- `docs/board.md` — append `[[sp###|<title>]]` under `## idea`.

The `ft###` is **not** minted by this skill — the capability boundary is still under discussion. Minting at `spec-writing` time avoids a half-formed feature ending up in the registry.

## Entry-specific checklist

1. **Dedup check.** `feature-read` filtered by keyword. Close match → re-route to `idea-extend` on that `ft###` and stop.
2. **Identify consumers via `im###`.** `implementation-read` filtered by keyword. Each `im###`'s `solves` link surfaces the consumer story transitively. Zero or one plausible consumer is a red flag — features are reusable by definition. Do not direct-search `us###` at this stage; the lifecycle contract reads `im###` here.
3. **Granularity check (ft### level).** Does the ask pack multiple distinct capabilities into "one feature"? Each capability with its own `## providing` paragraph, its own `## api_surface`, its own consumer set, or its own lifecycle is a separate `ft###`. The `ft###` schema is single-`providing` / single-`api_surface` / single-`status` — if the ask cannot coherently fit that shape, it is N capabilities, not one. Surface that count explicitly; never let a monolithic "platform" / "stack" / "system" feature slip through as a single `ft###`.
4. **Inventory ad-hoc implementations.** `implementation-read` filtered by keyword. List migration candidates.
5. **Categorize.** Survey via `category-read`. Horizontal capabilities typically live in 1-2 categories.
6. **Survey binding ADRs** under the picked categories via `adr-read`.
7. **Migration sketch.** One-line note per ad-hoc `im###` on migration cost.
8. **Sizing → sp### count.** If step 3 produced N capabilities, decide how many sp### to mint based on *size of work*, not capability count:
   - **N capabilities, small scaffolding of well-understood shapes** → one sp###. List all N `ft###` candidates in the `## problem`; the split happens at task level during `spec-refinement` / `spec-ready`.
   - **N capabilities, independent non-trivial work each** → N sp###, one per `ft###`. Each gets its own board lifecycle so they can ship independently.
   - **Default when unsure** → one sp###; splitting at task level is cheaper than splitting at sp### level. Promote to N sp### only when scope makes it obvious.
9. **Mint `sp###`(s)** with `## problem` covering capability + consumers + constraints + migration intent. List every `ft###` candidate explicitly. **Reference discipline:** every surveyed id that bears on the proposal lands in `## problem` as a wikilink — `[[ft###]]` for dedup-considered features, `[[im###]]` for consumer/migration targets, `[[cat###]]` for category picks, `[[adr####]]` for binding or conflicting decisions. Bare prose without ids fails the lifecycle contract.
10. **Update `docs/board.md`** under `## idea` — one entry per emitted sp###.

Walk the shared process around this checklist.

## Disambiguation

- **Capability that serves exactly one story** → re-route to `idea-implement` (it's `im###` glue, not `ft###`).
- **Modification to an existing feature** → re-route to `idea-extend` framed against the `ft###`.
- **Production-broken capability** → re-route to `idea-hotfix`.
- **Ask spans multiple distinct capabilities** ("observability stack", "notifications platform", "data layer") → N `ft###`, never one monolithic feature. Whether they ride in 1 sp### or N sp### is a sizing call (step 8) — small scaffolding → one sp### with task-level split, independent non-trivial work → N sp###.

## Key Principles (entry-specific)

- **A feature with one consumer is not a feature.** Features are reusable by definition. One-consumer "features" are `im###` glue in disguise.
- **Atomic feature, atomic `ft###`.** One `## providing` paragraph, one `## api_surface`, one lifecycle per `ft###`. Capabilities that would need an *or* in any of those fields are separate features. "Notifications" might be one feature (router) or three (email-send, slack-send, sms-send) — the schema's singletons force the answer. Granular features compose; monolithic features rot.
- **`ft###` granularity ≠ `sp###` granularity.** `ft###` is always atomic (above). `sp###` is a *deliverable workstream*; one sp### can scaffold multiple `ft###` when the work is small and the shapes are well understood, with the split landing at task level. Promote to N sp### only when the per-feature work is independent and non-trivial. Default to one sp###; splitting later is cheaper than merging later.
- **Constraints inherit from categories.** ADRs under the picked categories bind the feature automatically.
- **Migration is part of the proposal.** Listing the ad-hoc `im###` migration targets is what proves the feature pays for itself.
- **Stage-1 goals: problem-formulation + duplication-mitigation.** Per the lifecycle, every idea-* skill shares two objectives — help the user formulate a clear problem, and catch duplications in project context. The dedup check (step 1) and the wikilink reference discipline (step 9) carry the duplication-mitigation half; the survey-then-question cadence from `idea-brainstorming` carries the problem-formulation half.

## Integration

**Calls:**

- `infinifu:feature-read` / `implementation-read` / `category-read` / `adr-read` — AKM context survey (no `story-find` / `story-read` — lifecycle reads `im###` for consumers).
- `infinifu:idea-brainstorming` — shared process basics.
- `infinifu:spec-writing` — the only next step after design approval; it mints `ft###`.
