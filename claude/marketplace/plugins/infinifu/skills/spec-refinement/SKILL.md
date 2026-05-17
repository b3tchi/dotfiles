---
name: spec-refinement
description: "You MUST use this when an existing spec has a chosen solution and needs to be turned into an executable plan — 'refine sp007', 'sp012 needs the SRE pass', 'sp001 has a solution, now break it down for execution', 'apply spec-refinement to sp004', or any phrasing that names a `sp###` at `status: spec` (with `## solution` populated) that needs `## plan` + `## tasks` written. Stage 3 of the AKM lifecycle (spec-refinement). The discipline is an SRE 8-category review: granularity, implementability, success criteria, dependencies, safety standards, edge cases, red flags, test meaningfulness — applied across the task breakdown. Plus a sanity-check pass against binding `[[adr####]]` (decisions the spec must respect) and consumed `[[ft###]]` (capabilities the spec calls into). Finalize the back-link `## specs` on the consumed `[[im###]]`. Does NOT use bd, NOT promote status, NOT touch the board — those are spec-ready scope."
---

# Spec Refinement (## solution → ## plan + ## tasks)

## Overview

Stage 3 of the AKM lifecycle. A spec is at `status: spec` with `## solution` populated. The user wants the plan + task breakdown that makes the solution executable. This is the SRE pass: junior engineer must be able to pick up any single task and ship it with zero questions.

**Three deliverables, all on the spec file:**

1. **`## plan`** — file tree, conventions, anti-patterns, known limitations. The execution context every task inherits.
2. **`## tasks`** — H3 per task (`### Task N: <name>`) with H4 properties (`#### type`, `#### effort`, `#### depends`, `#### files_touched`, `#### success_criteria`, `#### edge_cases`, `#### test_plan`). No `#### bd` ids — those land in `spec-ready`.
3. **Sanity check** against binding `[[adr####]]` and consumed `[[ft###]]` — the solution shape from stage 2 was a *proposal*; here we verify the breakdown actually respects every ADR's `## decision` and matches every Feature's `## api_surface`. Find conflicts now, before tasks ship.
4. **Finalize `## specs` back-link on the consumed `[[im###]]`** — close the graph so `spec-retro` can find the trail.

**Out of scope (deliberately deferred):**

- bd epic / task creation → `spec-ready`
- Status promotion `spec → ready` → `spec-ready`
- `board.md` move `## spec → ## ready` → `spec-ready`
- Minting a new `im###` from scratch → that happened upstream; this skill only finalizes the back-link

**Announce at start:** "Using spec-refinement skill — SRE 8-category pass + ADR/Feature sanity."

## AKM hooks

Stage 3 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Lifecycle goal: ensure deliverable workable — SRE 8-category pass.

**Reads** (per lifecycle contract):

- `sp###` — target spec at `status: spec`. Read frontmatter, `## solves [[us###]]`, `## solution`, the H1 categories.
- `us###` — re-read source story's `## acceptance_criteria`. Every task's `#### success_criteria` should map to one or more AC. (Reading the story is required to validate that the breakdown actually delivers AC, not invented criteria.)
- `im###` — the implementation card this spec implements. Its `## approach`, `## features`, `## components` constrain the breakdown. Finalize `## specs` back-link.
- `adr####` (`adr-read --category <picks>`) — every `Accepted` ADR under the spec's categories. The task list must not violate any `## decision`; if it does, name a supersession candidate (do not silently violate).
- `ft###` (`feature-read`) — every `[[ft###]]` listed in the spec's `## solution`. Each task that consumes a feature must call its `## api_surface` exactly; document any deviation as a Feature-extension request.

**Writes:**

- `sp###` — same file. Append `## plan` + `## tasks`. **Reference discipline:** every consumed feature, binding ADR, category, and source us appears as a wikilink in `## plan` or in the relevant task's H4 properties.
- `im###` — same file. Append the back-link `## specs - [[sp###]]` so the graph closes.

## SRE 8-category checklist (applied to every `### Task N`)

| # | Category | Key questions | Auto-reject if |
|---|---|---|---|
| 1 | Granularity | Each task 4-8h? Phases ≤16h? | Any task >16h with no breakdown |
| 2 | Implementability | Junior can execute without questions? File paths explicit? | Vague language, "implement properly" |
| 3 | Success criteria | 3+ measurable criteria per task? Tied to a `us###.AC` line? | Subjective criteria ("works well"); no AC link |
| 4 | Dependencies | `#### depends` correctly references earlier task ids? No cycles? | Circular deps; missing prerequisite |
| 5 | Safety standards | `#### anti-patterns` or `## plan` anti-patterns section present? Error handling explicit? | No anti-patterns; raw unwrap/panic allowed |
| 6 | Edge cases | Empty input? Unicode? Concurrency? Failures? | No `#### edge_cases` content |
| 7 | Red flags | Placeholder text? "[detailed above]"? "TODO" in the spec? | Any placeholder found |
| 8 | Test meaningfulness | Tests catch real bugs? Not tautological? Per-test scenario named? | Tests verify syntax/existence only; "test_basic" |

**Reject the breakdown** if any auto-reject row trips on any task. Rewriting in place is cheaper than shipping a broken task list.

## ADR / Feature sanity (after SRE pass)

After the 8-category pass produces a clean breakdown, run two cross-cutting sanity checks:

### ADR sanity

For every `Accepted` `[[adr####]]` whose category overlaps the spec's H1 categories:

- Re-read the ADR's `## decision` and `## consequences`.
- Walk every task in the breakdown; flag any task whose chosen approach contradicts the decision.
- If the spec genuinely needs to overturn an ADR, the breakdown must include a Task: "File new ADR superseding [[adr####]]" before any task that depends on the new direction. Silent violation = ship-blocker.

### Feature sanity

For every `[[ft###]]` consumed (per the spec's `## solution`):

- Re-read the Feature's `## api_surface`. Tasks that call it must match the surface exactly (function names, payload shapes, return types).
- Re-read the Feature's `## providing` paragraph. If the spec uses the feature in a way that isn't in `## providing`, that's a *Feature extension* — call it out as a separate task that goes through `idea-extend` on that `ft###` first.
- Re-read `## data_model`. Tasks that mutate the feature's owned state need explicit coordination (lock, transaction, idempotency); flag if missing.

## Entry-specific checklist

1. **Identify target spec.** User names a `sp###`. Verify `docs/notes/spec/sp###.md` exists.
2. **Verify status.** Must be `status: spec`. Apply Disambiguation if not.
3. **Read the spec body** — `## solves`, `## solution`, H1 categories.
4. **Re-read source `us###.acceptance_criteria`.** Every task's success criteria will map here.
5. **Read consumed `[[im###]]`** — `## approach`, `## features`, `## components` constrain the breakdown.
6. **Survey ADRs** under the spec's categories. Note `Accepted` decisions that bind.
7. **Survey Features** in `## solution`. Note `## api_surface` + `## providing` per feature.
8. **Draft `## plan`** — file tree, conventions, anti-patterns, known limitations.
9. **Draft `## tasks`** — H3 per task with the H4 property set (`type`, `effort`, `depends`, `files_touched`, `success_criteria`, `edge_cases`, `test_plan`). No bd ids.
10. **Apply SRE 8-category pass** to every task. Reject and rewrite if any auto-reject row trips.
11. **ADR sanity pass.** Flag any conflict; add supersession task if needed.
12. **Feature sanity pass.** Flag api-surface mismatches; route Feature extensions through `idea-extend`.
13. **Surface as design-approval gate** to the user — the breakdown is a commitment, not a proposal. User approves before continuing.
14. **On approval:** write `## plan` + `## tasks` into the spec file; append `## specs - [[sp###]]` to the consumed `im###`.

## Disambiguation

- **`sp###` does not exist** → block. Route to an idea-* skill or spec-writing depending on where the gap is.
- **`sp###` at `status: idea`** → no solution chosen yet. Route to `spec-writing`.
- **`sp###` at `status: ready`** → already refined and queued. Route to `work-do` (or `spec-retro` after merge).
- **`sp###` at `status: done`** → shipped. Nothing to refine.
- **`sp###` at `status: spec` but `## solution` missing/empty** → block. Route back to `spec-writing` to populate solution first.
- **Source `us###.AC` empty or vague** → block. Route back to `idea-implement` / `idea-extend` for AC refinement. Tasks cannot map to AC that don't exist.
- **No `[[im###]]` referenced in `## solution`** → block. Spec-writing should have either named the consumed `im###` or marked dedup against an existing one; either way the back-link can't be finalized here without it.

## Key Principles (entry-specific)

- **SRE pass is the deliverable.** Without the 8-category check, the breakdown is just a task list — the discipline is what makes it executable by a junior engineer who reads only the spec.
- **AC bind every task.** Each task's `#### success_criteria` ties back to one or more lines from `us###.## acceptance_criteria`. A task whose success criteria don't trace back to AC is either out of scope or AC are incomplete (block).
- **ADR sanity, not just survey.** Knowing the ADRs exist isn't enough — walk every task and verify the chosen approach respects each `Accepted` decision. Silent ADR violation is the #1 source of post-merge rework.
- **Feature surface, not feature intent.** Tasks must call `## api_surface` exactly. If the spec needs functionality outside the Feature's `## providing`, that's a Feature extension via `idea-extend`, not a silent over-reach in the task list.
- **No bd ids at this stage.** Annotating `#### bd <id>` is `spec-ready`'s job. Doing it here couples task structure to bd state machine and slows iteration.
- **Reject placeholder text.** Anything matching "[detailed above]", "[as specified]", "[will be added during implementation]" is an auto-reject. Read back the spec body after every edit; reject if a placeholder slipped in.

## Integration

**Calls:**

- `infinifu:spec-read` — fetch target sp### + verify status/body.
- `infinifu:story-read` — re-read source us###'s AC.
- `infinifu:implementation-read` — read consumed im###'s approach/features/components.
- `infinifu:category-read` / `adr-read` / `feature-read` — context survey + sanity pass.
- `infinifu:domain-test-effectiveness` — when grading test_plan blocks for tautology / coverage gaming.
- `infinifu:idea-brainstorming` — shared process basics (reference, not router).
- `infinifu:idea-extend` — route here when Feature sanity surfaces an extension need.
- `infinifu:spec-ready` — the only next step after the user approves the breakdown.

**Out of scope (do NOT call from here):**

- `bd` — task creation belongs to `spec-ready`. No `bd create`, no `bd update`, no `bd dep add` from this skill.
- Status promotion — `sp###.status` stays at `spec` after this skill runs.
- `board.md` — board listing stays in `## spec`. Move happens at `spec-ready`.
