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

- Status flips on `us###` / `im###` / `sp###` — `work-merge`'s epic finale did those (auto-fired by `work-audit` when the last task closed).
- `docs/board.md` `## ready → removed` + `docs/archive.md ## done` append — `work-merge`'s epic finale did those.
- Per-task local merges of `bd-<id>` branches — `work-merge` ran one per task as `work-audit` approved each. By the time spec-retro runs, base already carries every bd-<id> merge commit locally.
- Per-task worktree removal — `work-merge` removed each as part of per-task land. Step 13 here is a safety net that should usually report `0 removed`.
- Running tests — `work-merge`'s per-task land already gated each merge with the post-merge test command.

**Owned by spec-retro (not upstream):**

- `git push` and `bd dolt push` (step 14). work-merge stayed local; spec-retro syncs everything to remote in one push so the AKM archive commit and the retro graph-refresh land together with the bd-task merges.

**Announce at start:** "Using spec-retro skill to refresh the AKM graph post-merge."

## AKM Workspace Resolution

The implementation card, new ADRs, updated features, new story drafts, and the product hub are shared knowledge — they live on **main**, even though the diff being analyzed shipped on a feature branch. Resolve before any read or write:

```bash
AKM_ROOT="$(akm-root)"
```

`akm-root` returns the main-worktree path (default branch); outside git, cwd. Anchor every AKM path on `$AKM_ROOT` (`$AKM_ROOT/docs/notes/im<NNN>.md`, `$AKM_ROOT/docs/notes/adr<NNNN>.md`, `$AKM_ROOT/docs/notes/ft<NNN>.md`, `$AKM_ROOT/docs/notes/us<NNN>.md`, `$AKM_ROOT/docs/product.md`, `$AKM_ROOT/docs/notes/archive/spec/sp<NNN>.md` — the delivered spec, relocated into the archive mirror by work-merge). The diff itself (`git log` / `git diff`) is read from whichever worktree merged the work; only the AKM writes have to land under `$AKM_ROOT`. If `akm-root` errors, surface its stderr and abort — never silently land retro mutations on the feature branch.

spec-retro is a **transition skill that commits on main** per the AKM commit policy. The post-merge knowledge-graph refresh is multi-file and lands as one retrospective commit covering every zettel touched:

```bash
git -C "$AKM_ROOT" add docs/notes/im<NNN>.md docs/notes/adr<NNNN>.md docs/notes/ft<NNN>.md docs/notes/us<NNN>.md docs/product.md
git -C "$AKM_ROOT" commit -m "feat(akm): retro sp<NNN>"
```

Commit-message convention: `feat(akm): retro sp<NNN>` — base form. When the retro mints additional zettels, extend the subject with the new ids in brackets, e.g. `feat(akm): retro sp012 [+ adr0014, ft007, us023]`. Stage every file actually changed (some retros touch only `im###`; others touch all five categories). See the per-stage commit table in `docs/notes/akm.md#workspace-resolution`.

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

- `$AKM_ROOT/docs/notes/im###.md` — rewrite `## approach` / `## components` / `## data_model` / `## api_surface` body sections. Keep the frontmatter (`status: accepted`); only the narrative changes. **Reference discipline:** every consumed `ft###`, binding `adr####`, and source `us###` continues to appear as wikilinks.
- `$AKM_ROOT/docs/notes/adr####.md` — mint a *new* ADR file (four-digit zero-padded next id) per decision that shifted. If the new ADR supersedes an Accepted one, flip the old ADR's `status: Accepted → Superseded` (in its own `$AKM_ROOT/docs/notes/adr####.md`) and append `## superseded_by` with the new wikilink.
- `$AKM_ROOT/docs/notes/ft###.md` — update body sections in place when the feature's surface widened compatibly. If incompatible, mint a new `ft###` and supersede the old one via `## superseded_by`.
- `$AKM_ROOT/docs/notes/us###.md` — draft new stories (`status: draft`) for follow-up scope. Use `story-write` to ensure the schema is right (frontmatter aliases / status / created, body role / want / because / acceptance_criteria).
- `$AKM_ROOT/docs/product.md` — add `>> [[im<NNN>]]` annotation to the source story bullet under `## Stories` (lifecycle hook: shipped story gets its implementation link).
- bd epic — `bd close <epic-id> --reason "Retro: <one-line summary>. Im rewritten. N new ADRs / M ft updates / K us drafts."`

## Entry-specific checklist

1. **Resolve AKM root.** `AKM_ROOT="$(akm-root)"` — every AKM path anchors on it. Abort with the helper's stderr if it errors.
2. **Identify target sp###.** Verify `$AKM_ROOT/docs/notes/archive/spec/sp###.md` shows `status: done` and the spec is listed under `$AKM_ROOT/docs/archive.md ## done` (work-merge relocated the delivered spec into the archive mirror and moved the board entry). If the file is still at `docs/notes/spec/sp###.md` or status is anything but `done`, work-merge hasn't run — route back to `work-merge`.
3. **Read the shipped diff.** `git log <merge-base>..HEAD --oneline` and `git diff <merge-base>..HEAD` for files under `src/` plus any moved AKM zettels. The diff is the ground truth.
4. **Compare diff vs spec.** Walk the `sp###.## tasks` blocks against the actual code change. For each task, note the file/function it landed in vs what the design predicted. Discrepancies feed the rewrite.
5. **Re-read `$AKM_ROOT/docs/notes/im###.md`.** Confirm the `## approach` / `## components` / `## data_model` / `## api_surface` reflect shipped reality. List the sections that need rewriting.
6. **Re-read each consumed `$AKM_ROOT/docs/notes/ft###.md`.** For each, check whether its `## api_surface` or `## providing` matches what the implementation actually called / consumed. List the features needing update.
7. **Cross-scan other `im###` for actual reuse, then propose Feature-extraction candidates** (pragmatic, not aggressive — see Key Principles). The goal: detect when code, modules, or capabilities written for *this* `im###` are *already* present in (or named by) at least one other shipped/in-flight Implementation — that's the evidence threshold for proposing a `ft###`. Speculative "feels reusable" doesn't qualify; concrete overlap with named, on-disk `im###` does.

   **Procedure:**

   a. List the candidate symbols from the just-shipped `im###`. Walk its `## components` (file paths) and `## approach` (named modules / helpers / utilities) and write down each unit that looks like generic capability rather than spec-specific glue — retry wrappers, validators, formatters, queues, schedulers, auth helpers, parsers, etc. Internal domain logic that only this `im###` would ever call (e.g. a wrapper named after the spec's specific business action) is **not** a candidate.

   b. For each candidate symbol, cross-scan `$AKM_ROOT/docs/notes/im*.md` for evidence of reuse:

      ```bash
      ls "$AKM_ROOT/docs/notes/"im*.md
      ```

      For each *other* `im###` file, read its `## components` and `## approach`. Look for:
      - the **same file path** appearing in its `## components`
      - the **same symbol / module name** referenced in its `## approach`
      - a **near-synonym** of the capability (e.g. `retry_with_jitter` here, `exponential_backoff` there — same shape, different name) that the two Implementations could share

   c. Tally consumers per candidate AND assess **correlation strength**. Two implementations can both touch a file and still not share a Feature — they may use it in incompatible ways. Apply the signal table:
      - **Strong correlation: 2+ `im###` use the same symbol with the same shape** — same function signature, same call site pattern, same expected behavior — and the capability is genuinely generic (not domain-specific glue with the same name) → **propose extraction**, name each consumer.
      - **Weak correlation: 2+ `im###` touch the same file but use it differently** — different signatures, different semantics, divergent error handling, or one is wrapping the other in a domain-specific way → **do NOT propose**. The "shared file" is incidental, not a Feature. Vertical over horizontal.
      - **1 other `im###` plus a named draft / planned story** with strong correlation → flag for human with both anchors named.
      - **Only this `im###` touches it, no others** → leave in `im###`. Speculative reuse is YAGNI; do not propose.

      Correlation test for each candidate: *"If I extract this to a `ft###` with one canonical signature, would im001 and im002 both consume it without per-consumer wrapping?"* If yes → strong, propose. If each consumer would still need a domain-specific adapter around the extracted code, the abstraction isn't ready — leave it as duplicated glue and let it bake.

   d. Surface findings as a `Candidate Features:` block in the final summary. **Each candidate must cite the other `im###` it would serve** — without the cross-reference, the candidate is speculative and shouldn't be raised:

      ```text
      Candidate Features:
      - ft-extract `retry_with_jitter` from im002 — also present in im005 (## components: src/utils/retry.go) and named in im007 (## approach: "exponential backoff with jitter"). Three consumers: extract to ft###?
      - ft-extract `iso_date_parser` from im002 — only this im### touches it; not raised (single consumer).
      ```

   e. **The human always decides — never mint `ft###` automatically.** Three constraints stack here and all three must hold before any extraction happens:

      1. **Evidence**: cross-scan turned up actual on-disk consumers (not speculation).
      2. **Strong correlation**: the consumers use the same shape (not just the same file).
      3. **Human verification**: even when (1) and (2) both hold, leave the `Candidate Features:` block as a recommendation. Do **NOT** write a new `ft###.md`, do **NOT** edit the consuming `im###` files to point at a not-yet-minted Feature, do **NOT** assume agreement from past patterns. The user reads the candidate, decides whether to mint, and runs `feature-write` themselves (or asks you to). Vertical over horizontal stays the default; the cross-scan + correlation test just supply the human with concrete evidence — the call is theirs.

      If the user later confirms a candidate, that's a *separate* `feature-write` invocation, not part of this retro. This retro's deliverable is the candidate block; the mint, if it happens, is a future operation.

   **Why this matters.** Without the cross-scan, "would another im### consume this?" is a guess that drifts toward over-extraction (every helper looks reusable in the abstract). With the cross-scan, the proposal is grounded in named, on-disk evidence — the human sees *which* other Implementations would consume the extracted Feature, and the decision becomes concrete instead of speculative.
8. **Re-read every Accepted `$AKM_ROOT/docs/notes/adr####.md` under the spec's categories.** For each, check whether the implementation respected the decision. If a decision shifted, draft a new ADR.
9. **Mine bd notes for discovered scope.** `bd show <epic-id>` and `bd list --parent <epic-id>`. Walk each closed task's notes for "Discovered:" entries, deviation logs, and BLOCKED-then-resolved sequences. Each unique discovery becomes either a new `us###` draft or a follow-up task (filed at this stage if not already).
10. **Write the rewrites + new entries on main**, every path under `$AKM_ROOT`, in this order: ADRs first (decisions bind the rest), `ft###` updates next, `im###` rewrite next, `us###` drafts last, then `$AKM_ROOT/docs/product.md` to attach `>> [[im###]]` to the shipped story bullet. Feature-extraction candidates flagged in step 7 stay as a summary block for the human — do NOT mint `ft###` from a candidate without confirmation.
11. **Commit on main.** Stage every retro-touched file together and commit as one retrospective:
    ```bash
    git -C "$AKM_ROOT" add docs/notes/im<NNN>.md docs/notes/adr<NNNN>.md docs/notes/ft<NNN>.md docs/notes/us<NNN>.md docs/product.md
    git -C "$AKM_ROOT" commit -m "feat(akm): retro sp<NNN>"
    ```
    Extend the subject with new ids in brackets when the retro mints them, e.g. `feat(akm): retro sp012 [+ adr0014, ft007, us023]`. Only stage files that actually changed; a minimal retro may be `im<NNN>.md` alone.
12. **Close the bd epic** if not already closed by work-merge's epic finale. (work-merge closes the epic when the last child's audit lands; this step is a no-op idempotent guard for the rare case where the retro is the first thing to notice.) One-line reason summarizing what shipped + the count of zettels touched (e.g., "Retro: rotate_secret + scheduler + synthetic-check shipped. Rewrote im002, minted adr0004 (lock granularity), updated ft002 (rotate_secret surface), drafted us004 (cross-region failover). Candidates flagged: ft-extract `retry_with_jitter` from im002 — would also serve us005").
13. **Sweep merged worktrees (safety net).** work-merge removes each worktree as the per-task land succeeds, so this should usually report `0 removed`. The sweep exists for edge cases: a script that errored mid-cleanup, a sibling worktree from a parallel pipeline, or a manually-created worktree that happens to be on a merged `bd-<id>` branch. Run:

    ```bash
    bash <skill-path>/spec-retro/scripts/sweep-merged-worktrees.sh "$AKM_ROOT"
    ```

    The script (see `scripts/sweep-merged-worktrees.sh`):
    - `fetch --prune`, then resolves `origin/HEAD` as base.
    - Walks `git worktree list --porcelain` for branches matching `^bd-`.
    - For each, checks `merge-base --is-ancestor` against `origin/<base>` — only merged branches get touched.
    - Removes with `git worktree remove` (no `--force`; refuses if uncommitted/untracked work present — investigate before forcing).
    - Deletes the local branch with `git branch -d` (safe, not `-D`).
    - Final `git worktree prune` + one-line summary `removed / kept / skipped`.

    Non-`bd-<id>` worktrees and unmerged branches are out of scope. Pass the script output through in the final report so the user can act on survivors.
14. **Push to remote.** spec-retro owns remote sync; work-merge stayed local. Push base, the AKM commits (archive + retro), and any new tags:

    ```bash
    git -C "$AKM_ROOT" pull --rebase    # pick up anything else that landed on remote while we worked
    bd dolt push                         # bd state (closed epic, audit notes, retro reason) — needs to land before code refs the closed epic
    git -C "$AKM_ROOT" push              # base + AKM admin commits
    git -C "$AKM_ROOT" status            # MUST show "up to date with origin"
    ```

    This is the gesture that the project's `Session Completion` workflow (see `CLAUDE.md`) calls out — work is not complete until `git push` succeeds. spec-retro is the canonical place that gesture fires; do NOT defer to the user "to push when ready". If push fails (conflict, auth, hook), resolve and retry until it succeeds — leaving local commits stranded is a regression of the whole flow.

    If you're on a feature branch (no upstream, or branch isn't base), confirm with the user before pushing: a stray `git push` of an experimental branch can pollute the remote. The typical run is on `main` / `master` because work-merge's per-task lands already moved every bd-<id> into base.
15. **Verify.** AKM retro commit landed on main (`git -C "$AKM_ROOT" log -1 --oneline` matches `feat(akm): retro sp<NNN>`); every file path under `$AKM_ROOT`; bd epic shows `closed`; `git worktree list` no longer shows the current spec's worktree; `git status` shows `up to date with origin`.

## Disambiguation

- **`sp###` does not exist** → block.
- **`sp###` at `status: idea` / `spec` / `ready`** → route back to the appropriate stage; spec-retro is post-merge only.
- **`sp###` at `status: done` but board entry still on `$AKM_ROOT/docs/board.md ## ready`** → work-merge didn't finish its archive move; route back to `work-merge`.
- **Branch not actually merged** (no merge commit visible from `git log <base>..HEAD`) → block; nothing shipped to retro on.
- **bd epic already closed** → either retro already ran (idempotent re-run is fine if you just want to verify) or someone closed the epic out-of-process. Verify with `bd show <epic-id> --reason` and either proceed (if reason was retro-shaped) or restore.

## Key Principles (entry-specific)

- **Diff is ground truth, spec is history.** When the shipped code differs from the spec, the retro updates the `im###` body to match shipped — not the other way around. The spec is the historical record of what was planned; the implementation is what runs.
- **ADRs are immutable.** New decisions = new ADRs (next sequential id, four-digit). Decisions that overturn old ones = new ADR + supersede the old one via the body section. Never edit an Accepted ADR's `## decision`.
- **Feature widening: update in place; feature changing: supersede.** If the feature's `## providing` covers the new use, just widen the `## api_surface`. If the consumer needed something the feature genuinely didn't offer, that's a supersession candidate (new `ft###` + `## superseded_by` chain on the old one).
- **ADR vs Feature — where does the finding go?** When execution surfaces something new, classify before writing. ADRs sit at the *strategic* level (vendor / paradigm / security stance / language-stack / cross-cutting policy — commitments that close off alternatives and are expensive to reverse). Features sit at the *implementation-near reusable* level (a concrete capability with `## api_surface`, `## data_model`, `## sample`, `## components` — building blocks many Implementations consume). Use this discriminator:

  | Finding | Goes into |
  |---|---|
  | "We decided X over Y" (vendor, library, paradigm, encoding, protocol) | new `adr####` |
  | Cross-cutting policy locked in (auth strategy, retry semantics, data residency, isolation level) | new `adr####` |
  | An option was foreclosed during shipping (e.g. "no more SQLite — Postgres only from now") | new `adr####` (often superseding an old one) |
  | New endpoint / API signature / schema / message contract any consumer can call | `ft###` widening (or new `ft###` if the contract shifted incompatibly) |
  | New module / file / sample showing how to consume an existing capability | `ft###` update (`## components` + `## sample`) |
  | Behavior or constraint of an existing service genuinely changed | `ft###` supersession chain |
  | Both a strategic choice *and* the capability it produced | **one of each** — ADR records the decision, Feature records the surface |

  Test: "Could a future engineer choose this differently?" Yes → ADR (it's a commitment). "Could a future engineer reuse this?" Yes → Feature (it's a building block). Both → both.

- **Feature extraction is evidence-based AND requires strong correlation — vertical stays over horizontal.** Step 7 mandates a cross-scan of every other `$AKM_ROOT/docs/notes/im*.md` for actual reuse of the candidate symbol *before* a `ft###` is proposed. The cross-scan only justifies a candidate when correlation is **strong** — the same shape used the same way. Two implementations touching the same file in different ways is not a Feature, it's coincidence. Default bias stays *leave glue in `im###`*:

  | Signal (evidence from the cross-scan) | Action |
  |---|---|
  | 2+ shipped or in-flight `im###` use the **same symbol with the same shape** (same signature, same call pattern, no per-consumer wrapping) | propose `ft###` extraction; name each consumer `im###` in the candidate block |
  | 2+ `im###` touch the same file but use it **differently** (divergent signatures, semantics, error handling) | leave in `im###` — weak correlation; the shared file is incidental, not a Feature |
  | 1 shipped `im###` + 1 named draft `us###` whose `## want` clearly needs the same shape | flag as candidate; cite both anchors so the human decides |
  | Only this `im###` touches the code; no other `im*.md` mentions it | leave in `im###` — speculative reuse is YAGNI, do not raise |
  | Internal helper used only by this `im###` (spec-specific business glue) | leave in `im###` — not a Feature |
  | Domain-specific wrapper around an existing shared `ft###` | leave in `im###` — that's the vertical layer the Feature already serves |

  Why evidence-based: premature Feature extraction freezes the wrong API surface. The cost of a wrong `ft###` is *higher* than the cost of duplicated glue — `ft###` enters the append-only-contract regime and every consumer pays the abstraction tax. Guessing "this looks reusable" gives one false positive per retro and the Feature catalog rots. Reading the other `im###` files takes a few seconds and turns the proposal into a concrete pointer ("would also serve `im005` and `im007`") the human can evaluate in one glance.

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

- Status flips on `us###` / `im###` / `sp###` — work-merge's epic finale did those.
- `docs/board.md` / `docs/archive.md` edits — work-merge's epic finale did those.
- Per-task local merges + worktree removal — work-merge did those per task as work-audit approved each.
- Running tests — work-merge already gated each per-task land.
- PR creation / `gh pr create` — out of scope for the local-only flow. If a project wants PRs, that's a separate skill / future extension; spec-retro pushes to remote and stops.
