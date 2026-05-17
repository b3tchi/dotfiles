---
name: spec-retro
description: "You MUST use this after work-merge completes — 'retro sp007', 'run the retrospective for the rotate-credentials spec', 'sp001 just merged, refresh the AKM graph', or any phrasing that asks for the post-merge knowledge-graph pass on a `sp###` whose status flipped to `done`. Stage 8 (final) of the AKM lifecycle. Reads the shipped diff plus the touched `im###` / `ft###` / `adr####`, then rewrites `im###` body to match shipped reality (the `accepted` card becomes source of truth), mints new `adr####` for decisions that shifted during execution (ADRs are immutable — supersede via new entry, never edit), updates `ft###` whose surface or constraints widened (or supersede via `## superseded_by`), drafts new `us###` for follow-up scope discovered, and closes the bd epic. Does NOT flip statuses (work-merge did that), NOT touch board.md / archive.md (work-merge did that), NOT run tests (work-merge did that)."
---

# Spec Retro (post-merge knowledge-graph refresh)

## Overview

Stage 8 of the AKM lifecycle — the final pass. The work has shipped (`sp###.status: done`, sp### moved from `docs/board.md` to `docs/archive.md`, all child bd tasks closed by `work-audit`, branch landed by `work-merge`). The job here is to update the persistent knowledge graph so future zettels reference shipped reality, not the proposed-stage narrative.

**Four lifecycle writes:**

1. **Rewrite `im###` body** — `## approach`, `## components`, `## data_model`, `## api_surface` get rewritten to describe what shipped. The `accepted` card is the persistent solution record; the `proposed`-stage narrative was a sketch.
2. **Mint new `adr####`** for each decision that shifted during execution. ADRs are append-only in spirit — if you discover a decision was made (or unmade), file a *new* ADR rather than editing an existing one. If the new ADR overturns an `Accepted` one, set the old ADR `status: Superseded` and add a `## superseded_by` back-link to the new id.
3. **Update `ft###`** where the consumed feature's surface or constraints actually widened during execution. Wider `## api_surface` or `## providing` → update in place if the feature already covers it; if the contract genuinely changed (incompatible signature, removed behavior), supersede via `## superseded_by` chain instead.
4. **Draft new `us###`** for any follow-up scope discovered during execution — bugs the team chose to defer, capabilities the implementation made tractable, edge cases that became visible. These land at `status: draft` so the next `idea-implement` cycle can pick them up.

Then close the bd epic.

**Out of scope (already done upstream):**

- Status flips on `us###` / `im###` / `sp###` — `work-merge` did those.
- `docs/board.md` `## ready → removed` + `docs/archive.md ## done` append — `work-merge` did those.
- Branch landing / PR / worktree cleanup — `work-merge` did those.
- Running tests — `work-merge`'s precondition was green tests; if you arrived here, they passed.

**Announce at start:** "Using spec-retro skill to refresh the AKM graph post-merge."

## AKM hooks

Stage 8 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Read shipped reality, write back into the persistent graph.

**Reads:**

- **Shipped diff** — `git log` and `git diff <merge-base>..HEAD` for the merge commit. The actual code change is the source of truth for the rewrite.
- `sp###` — the just-archived spec (now at `status: done`). Read `## solution`, `## plan`, `## tasks` to compare against what shipped.
- `im###` — the implementation card whose body needs refreshing. Currently at `status: accepted` per work-merge.
- `ft###` — every feature consumed by the spec. Read `## api_surface`, `## providing`, `## data_model` to know what may need updating.
- `adr####` — every Accepted ADR under the spec's categories. Decisions may have shifted; surface candidates for new ADRs.
- bd epic + closed tasks — task notes carry the implementer's deviations and the auditor's findings, both of which feed the retro.

**Writes:**

- `im###` — rewrite `## approach` / `## components` / `## data_model` / `## api_surface` body sections. Keep the frontmatter (`status: accepted`); only the narrative changes. **Reference discipline:** every consumed `ft###`, binding `adr####`, and source `us###` continues to appear as wikilinks.
- `adr####` — mint a *new* ADR file (`docs/notes/adr####.md`, four-digit zero-padded next id) per decision that shifted. If the new ADR supersedes an Accepted one, flip the old ADR's `status: Accepted → Superseded` and append `## superseded_by` with the new wikilink.
- `ft###` — update body sections in place when the feature's surface widened compatibly. If incompatible, mint a new `ft###` and supersede the old one via `## superseded_by`.
- `us###` — draft new stories (`status: draft`) for follow-up scope. Use `story-write` to ensure the schema is right (frontmatter aliases / status / created, body role / want / because / acceptance_criteria).
- bd epic — `bd close <epic-id> --reason "Retro: <one-line summary>. Im rewritten. N new ADRs / M ft updates / K us drafts."`

## Entry-specific checklist

1. **Identify target sp###.** Verify `sp###.status: done` and it lives under `docs/archive.md ## done` (work-merge precondition). If status is anything else, route back to `work-merge`.
2. **Read the shipped diff.** `git log <merge-base>..HEAD --oneline` and `git diff <merge-base>..HEAD` for files under `src/` plus any moved AKM zettels. The diff is the ground truth.
3. **Compare diff vs spec.** Walk the `sp###.## tasks` blocks against the actual code change. For each task, note the file/function it landed in vs what the design predicted. Discrepancies feed the rewrite.
4. **Re-read `im###`.** Confirm the `## approach` / `## components` / `## data_model` / `## api_surface` reflect shipped reality. List the sections that need rewriting.
5. **Re-read each consumed `ft###`.** For each, check whether its `## api_surface` or `## providing` matches what the implementation actually called / consumed. List the features needing update.
6. **Re-read every Accepted `adr####` under the spec's categories.** For each, check whether the implementation respected the decision. If a decision shifted, draft a new ADR.
7. **Mine bd notes for discovered scope.** `bd show <epic-id>` and `bd list --parent <epic-id>`. Walk each closed task's notes for "Discovered:" entries, deviation logs, and BLOCKED-then-resolved sequences. Each unique discovery becomes either a new `us###` draft or a follow-up task (filed at this stage if not already).
8. **Write the rewrites + new entries** in this order: ADRs first (decisions bind the rest), `ft###` updates next, `im###` rewrite next, `us###` drafts last.
9. **Close the bd epic** with a one-line reason summarizing what shipped + the count of zettels touched (e.g., "Retro: rotate_secret + scheduler + synthetic-check shipped. Rewrote im002, minted adr0004 (lock granularity), updated ft002 (rotate_secret surface), drafted us004 (cross-region failover)").

## Disambiguation

- **`sp###` does not exist** → block.
- **`sp###` at `status: idea` / `spec` / `ready`** → route back to the appropriate stage; spec-retro is post-merge only.
- **`sp###` at `status: done` but board entry still on `docs/board.md ## ready`** → work-merge didn't finish its archive move; route back to `work-merge`.
- **Branch not actually merged** (no merge commit visible from `git log <base>..HEAD`) → block; nothing shipped to retro on.
- **bd epic already closed** → either retro already ran (idempotent re-run is fine if you just want to verify) or someone closed the epic out-of-process. Verify with `bd show <epic-id> --reason` and either proceed (if reason was retro-shaped) or restore.

## Key Principles (entry-specific)

- **Diff is ground truth, spec is history.** When the shipped code differs from the spec, the retro updates the `im###` body to match shipped — not the other way around. The spec is the historical record of what was planned; the implementation is what runs.
- **ADRs are immutable.** New decisions = new ADRs (next sequential id, four-digit). Decisions that overturn old ones = new ADR + supersede the old one via the body section. Never edit an Accepted ADR's `## decision`.
- **Feature widening: update in place; feature changing: supersede.** If the feature's `## providing` covers the new use, just widen the `## api_surface`. If the consumer needed something the feature genuinely didn't offer, that's a supersession candidate (new `ft###` + `## superseded_by` chain on the old one).
- **Discovered scope becomes drafts, not silent edits.** New `us###` at `status: draft` is the cheapest moment to capture follow-up work. The next `idea-implement` cycle picks them up. Don't expand silently into the closing epic.
- **Bd epic close carries the retro signal.** The `--reason` text is the one-line summary the team will see when they search history later. Make it specific: counts, names, what shifted.
- **Out of scope: status flips.** work-merge did them. Don't re-flip anything; if a status is wrong, route back to work-merge instead.

## Integration

**Calls:**

- `git log <merge-base>..HEAD` / `git diff` — shipped reality.
- `infinifu:spec-read` — fetch the archived sp###.
- `infinifu:implementation-read` — re-read im### body to identify rewrite targets.
- `infinifu:feature-read` — survey consumed ft### surfaces.
- `infinifu:adr-read` — survey binding ADRs.
- `infinifu:story-write` — emit new `us###` drafts for discovered scope.
- `infinifu:adr-write` — mint new ADRs.
- `infinifu:feature-write` — update ft### bodies or supersede.
- `infinifu:implementation-write` — re-emit im### (same id, refreshed body).
- `bd show <epic-id>` / `bd list --parent <epic-id>` — mine task notes for discoveries.
- `bd close <epic-id> --reason "..."` — close the epic.

**Called after:**

- `infinifu:work-merge` Option 1 (local merge) or Option 2 (PR). Options 3 / 4 skip spec-retro because nothing shipped.

**Out of scope (do NOT call from here):**

- Status flips on `us###` / `im###` / `sp###` — work-merge did those.
- `docs/board.md` / `docs/archive.md` edits — work-merge did those.
- Branch / worktree / PR operations — work-merge did those.
- Running tests — work-merge already gated.
