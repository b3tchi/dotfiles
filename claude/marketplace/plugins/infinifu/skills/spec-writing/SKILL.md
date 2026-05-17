---
name: spec-writing
description: "You MUST use this when the user wants to choose how to solve a problem that's already captured on the board — 'sp007 has a problem, let's pick a solution', 'work out the approach for the rotate-credentials spec', 'propose the solution shape for sp012', or any phrasing that names an existing `sp###` at `status: idea` whose `## problem` is populated and now needs a high-level `## solution`. Stage 2 of the AKM lifecycle (spec-writing). Reads the story's `## acceptance_criteria`, surveys binding `cat`/`ft`/`adr` for the categories the spec touches, then writes `## solution` proposing the approach (ADR refs, consumed features) and flips the spec's `status: idea → spec` (board entry moves `## idea → ## spec`). Does NOT write tasks / file trees / bd ids — those belong to `spec-refinement` and `spec-ready`. The spec must already exist at `status: idea`."
---

# Spec Writing (idea → spec)

## Overview

Stage 2 of the AKM lifecycle. A spec is already on the board at `status: idea` with `## problem` populated (placed there by one of the idea-* skills). The user is asking you to choose **how** to solve that problem at a high level — which ADRs constrain the approach, which features will be consumed, which trade-offs to take — and to write that choice into the spec as `## solution`. The spec then flips `idea → spec` and its board listing moves with it.

**This skill does NOT write tasks, file trees, bd ids, or step-by-step plans.** Those are deliberately downstream:
- File tree / conventions / anti-patterns / task breakdown → `spec-refinement`
- bd epic + task ids → `spec-ready`

Keeping spec-writing narrow lets the solution shape stay revisable until the user approves it. Locking task structure here is what creates churn when the approach shifts.

**Announce at start:** "Using spec-writing skill to propose the solution shape."

## AKM hooks

Stage 2 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Lifecycle goals: propose solution for the problem at high level, ensure solution is in line with features and ADRs, ensure no duplication or propose possible made solution.

**Reads** (per lifecycle contract):

- `sp###` — the target spec at `status: idea`. Read `## solves [[us###]]` + `## problem` to know what's being solved.
- `us###.acceptance_criteria` — the testable criteria the solution must satisfy. The spec's solution shape is constrained by these AC.
- `cat###` (`category-read`) — taxonomy buckets the spec lives under (read from the spec's H1 wikilinks).
- `ft###` (`feature-read`) — capabilities the solution might consume. Bind concretely here (not just candidates as in idea-*).
- `adr####` (`adr-read --category <picks>`) — decisions binding the chosen categories. Solution must align with `Accepted` ADRs in scope; if it conflicts, surface as a supersession candidate, do not silently violate.

**Writes:**

- `sp###` — same file. Append `## solution` body section. **Reference discipline:** every relevant id appears as a wikilink in `## solution` — `[[ft###]]` for consumed features, `[[adr####]]` for binding decisions, `[[cat###]]` for taxonomy alignment. Prose-only solutions break the graph for spec-refinement downstream.
- `sp###` — flip frontmatter `status: idea → spec`.
- `docs/board.md` — move the `[[sp###]]` entry from `## idea` to `## spec`.

## Entry-specific checklist

1. **Identify target spec.** User must name a `sp###` (by id or alias). Verify `docs/notes/spec/sp###.md` exists.
2. **Verify status.** Read frontmatter `status`. Must be `idea`. Apply Disambiguation if not.
3. **Read the spec.** Confirm `## solves [[us###]]` and `## problem` are populated. If `## problem` is missing or empty, block — route back to the originating idea-* skill.
4. **Re-read source us###.AC.** Fetch the story this spec solves; re-read `## acceptance_criteria`. If AC are vague or empty, block — route back to `idea-implement` (or `idea-extend`) for AC refinement. The solution shape is meaningless against shifting criteria.
5. **Survey categories** named in the spec's H1 — `category-read` on each.
6. **Survey binding ADRs** under those categories via `adr-read`. Identify which ones constrain the approach; flag any conflict between the natural solution and an `Accepted` ADR.
7. **Survey features** the solution will consume via `feature-read`. Where the problem mentioned candidate `[[ft###]]` ids, decide which actually bind; identify any new ones.
8. **Dedup check.** Does an existing `im###` already solve this story (or an adjacent one) in a way the new spec is about to duplicate? If yes, surface the duplicate and ask whether to extend the existing solution shape rather than mint a new one. Lifecycle goal: "ensure no duplication or propose possible made solution".
9. **Propose `## solution`.** One paragraph naming the approach + ADR refs + bound `[[ft###]]` consumed + the trade-offs taken. Surface this as the design-approval question — the user owns whether the proposed shape is the right one.
10. **On approval:** append `## solution` to the spec file with the wikilink reference discipline. Flip frontmatter `status: idea → spec`.
11. **Update `docs/board.md`** — remove the `[[sp###]]` entry from `## idea`, add it to `## spec` (same wikilink, same label).

Walk the shared process around this checklist (load `idea-brainstorming` for cadence + hard-gate basics — same conventions apply at every lifecycle stage).

## Disambiguation

- **`sp###` does not exist (file missing)** → block; the user is asking about a spec that hasn't been captured. Route to an idea-* skill to capture the problem first.
- **`sp###` at `status: spec`** → solution already chosen. Route to `spec-refinement` to add `## plan` + `## tasks`.
- **`sp###` at `status: ready`** → already refined and queued. Route to `work-do`.
- **`sp###` at `status: done`** → shipped; nothing to write.
- **`sp###` at `status: idea` but `## problem` is empty / missing** → block; route back to the originating idea-* skill to populate the problem first.
- **Source `us###.acceptance_criteria` is empty / vague** → block; route back to `idea-implement` (or `idea-extend`) to refine AC. Spec-writing cannot bind a solution to shifting criteria.
- **Existing `im###` already solves the same `us###`** → surface the duplicate; if the user wants a new approach, file the existing `im###` as a supersession candidate and continue; if not, stop.

## Key Principles (entry-specific)

- **Solution shape only — no task plumbing.** The output is `## solution`. File trees, task lists, bd ids belong downstream. Putting them here means the user has to approve them along with the solution, which conflates two decisions and slows iteration.
- **AC bind the solution.** A solution proposed against vague AC is a guess. The skill blocks at step 4 for exactly this reason.
- **ADRs constrain, don't reinvent.** An `Accepted` ADR under the picked categories binds the approach. If the natural solution conflicts, name it as a supersession candidate; never silently violate.
- **Feature consumption commits here.** Idea-* listed candidates; spec-writing picks the actual `[[ft###]]` set the solution will consume. Spec-refinement will design tasks against that set.
- **Dedup before mint.** If an existing `im###` already solves the same story, the new spec needs to either supersede it (named decision) or stop (don't duplicate). The lifecycle explicitly carries this goal at stage 2.
- **Reference discipline.** Every consumed `ft###`, binding `adr####`, and category `cat###` appears as a wikilink in `## solution`. The moxide LSP and downstream skills traverse the graph through those wikilinks.

## Integration

**Calls:**

- `infinifu:spec-read` — fetch target sp### + verify status/body.
- `infinifu:story-read` — fetch source us### + re-read AC.
- `infinifu:category-read` / `adr-read` / `feature-read` — context survey.
- `infinifu:implementation-read` — dedup check against existing im### that solves the same us###.
- `infinifu:idea-brainstorming` — shared process basics (reference, not invoked as router).
- `infinifu:spec-refinement` — the only next step after solution approval; it adds `## plan` + `## tasks`.

**Out of scope (do NOT call from here):**

- `bd` — task creation belongs to `spec-ready`.
- `implementation-write` minting a new `im###` — happens at `spec-refinement` once tasks are concrete enough to anchor an implementation card.
- File-tree / convention drafting — `spec-refinement`'s `## plan` section.
