---
name: idea-extend
description: "You MUST use this when the request adjusts behavior the system has already shipped — 'us007 should also do X', 'us005 is wrong', 'the bulk-rejection story needs a reason field', 'extend Y to support Z', or any phrasing that modifies an existing user-visible behavior backed by a known `us###`. Direct entry point for AKM lifecycle stage 1, *us changed adjust implementation* entry type. Captures the problem as `sp###.problem`, surfaces the affected `us###` + `im###`, and frames whether the implementation card needs supersession or just a body refresh after ship. Loads shared brainstorming basics from `infinifu:idea-brainstorming`."
---

# Idea: Extend (story changed)

## Overview

Direct entry point for the "us changed adjust implementation" entry type. A shipped story needs adjustment. Identify which `us###`, which `im###` it touches, what changes — but no code yet.

**Announce at start:** "Using idea-extend skill to scope a change to an existing story."

**Shared basics.** Process (context exploration, hard gate, question cadence, design approval, spec-writing handoff) lives in `infinifu:idea-brainstorming`. Load it before walking the checklist below.

## AKM Workspace Resolution

Specs and the board live on **main**, even from a feature-branch worktree.
Resolve before any file op:

```bash
AKM_ROOT="$(akm-root)"
```

Anchor every path on `$AKM_ROOT` (`$AKM_ROOT/docs/notes/spec/sp<NNN>.md`,
`$AKM_ROOT/docs/board.md`, and all `$AKM_ROOT/docs/notes/...` reads). If
`akm-root` errors, surface stderr and abort — never silently land an idea
on the feature branch.

**Commit policy:** stage only. `git -C "$AKM_ROOT" add docs/notes/spec/sp<NNN>.md docs/board.md`. No commit at idea phase — the downstream `spec-writing` skill commits when the idea graduates to a spec. See the per-stage table in `docs/notes/akm.md#workspace-resolution` and the fuller treatment in `infinifu:idea-brainstorming`.

## AKM hooks

Stage 1 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Entry type: **us changed adjust implementation**.

**Reads:**

- `pn###` (`persona-read`) — confirm the affected role is still validated; if retired, flag a re-routing question.
- `us###` (`story-read`) — the existing story being adjusted. Read in full; the AC will likely shift.
- `im###` (`implementation-read`) — the accepted implementation card. Read `## approach`, `## components`, `## api_surface`, `## data_model` so the proposal is concrete about what changes.
- `cat###` (`category-read`) — current categories on the `im###`. Adjustments rarely change category, but flag if they would.
- `adr####` (`adr-read --category <picks>`) — decisions that shaped the original `im###`. Flag any that the adjustment would overturn — overturning means a new ADR at spec-retro time.
- `ft###` (`feature-read`) — features the `im###` consumes. Flag any whose contract the adjustment would widen.

**Writes:**

- `sp###` — new zettel at `$AKM_ROOT/docs/notes/spec/sp<NNN>.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body: `## solves [[us###]]`, `## problem` describing the delta clearly (AC change, what stays, migration story for already-shipped data, supersession-or-refresh decision).
- `$AKM_ROOT/docs/board.md` — append `[[sp###|<title>]]` under `## idea`.

The `us###` is **not** mutated yet (AC may shift, but that lands at `spec-writing` / `spec-refinement`). The `im###` is **not** flipped yet (status changes at `work-merge`; body rewrite at `spec-retro`).

## Entry-specific checklist

1. **Resolve `AKM_ROOT="$(akm-root)"`** before any file op.
2. **Identify affected `us###`.** Confirm via `story-read` if ambiguous. Read in full.
3. **Find the implementing `im###`.** `implementation-read --solves us###`. No match → flag and either re-route or salvage.
4. **Read the implementation** — `## approach`, `## components`, `## api_surface`, `## data_model`.
5. **Survey binding ADRs** via `adr-read --category <im###'s categories>`. Flag overturns.
6. **Survey consumed features** via `feature-read`. Flag widened contracts.
7. **Frame supersession vs body refresh.** Capture the decision in `sp###.problem`.
8. **Mint `sp###`** at `$AKM_ROOT/docs/notes/spec/sp<NNN>.md` with the delta narrative.
9. **Update `$AKM_ROOT/docs/board.md`** under `## idea`.
10. **Stage on main.** `git -C "$AKM_ROOT" add docs/notes/spec/sp<NNN>.md docs/board.md`. Do **not** commit — spec-writing handles the first commit when the idea graduates.
11. **Confirm.** Surface the absolute `$AKM_ROOT/docs/notes/spec/sp<NNN>.md` path; confirm `git status` on main shows `A docs/notes/spec/sp<NNN>.md` and `M docs/board.md` with no commit created.

Walk the shared process around this checklist.

## Disambiguation

- **Strict bug** (existing AC violated, no behavior change needed) → re-route to `idea-hotfix`.
- **Behavior change without an existing story** → re-route to `idea-implement`.
- **Adjustment introduces a new horizontal capability** → re-route to `idea-feature` for the capability, then return here for the story-side adjustment.

## Key Principles (entry-specific)

- **Read the `im###` in full.** Adjustments without context produce broken proposals.
- **ADR conflicts are not silent.** Overturning an accepted decision is a separate cost the user must own.
- **Supersession or refresh is the headline call.** The whole downstream chain shapes around it.

## Integration

**Calls:**

- `infinifu:story-read` / `implementation-read` / `feature-read` / `adr-read` / `category-read` — AKM context survey.
- `infinifu:idea-brainstorming` — shared process basics.
- `infinifu:spec-writing` — the only next step after design approval.
