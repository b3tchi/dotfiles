# spec-retro run notes — sp001 (eval-3-nothing-to-harvest)

## Inputs (state at start)

- Spec: `docs/notes/spec/sp001.md` — frontmatter `status: done`, references `us003` / `im002` / `ft002`.
- bd epic: `wd3-268484-3ts` — OPEN, with 3 children all CLOSED (AUDITED: APPROVED).
- bd notes: clean. Task 1 evidence-block ends "Deviations: none"; Task 3 note says "No deviations". Task 2 had no notes.
- Shipped code: `src/lib/vault.py` (rotate_secret + per-name lock + alias bookkeeping), `tests/lib/test_vault.py` (5 tests, all pass).
- Story `us003`: already `status: done` in frontmatter; acceptance criteria match shipped surface.
- `docs/board.md` already shows empty "ready"; `docs/archive.md` already lists `[[sp001]]` under done.

## Step 1 — Validate Delivery

- `bd list` confirmed: 3/3 children closed, epic eligible to close.
- `python -m pytest tests/` → 5 passed.
- Found one untracked TODO in shipped code: `src/lib/vault.py:49` (set_timeout for European region). Per skill Step 1 ("if found, file `bd create 'Discovered: ...'` before closing"), filed as `wd3-268484-gqj` (P3) before closing the epic.

## Step 2 — Retrospective (evidence-based)

- **What went wrong:** nothing material — all three tasks closed clean, "No deviations" notes from the reviewer.
- **What went well:** spec's `test_plan` blocks per task gave the implementer a concrete checklist; audit was able to point at named tests as evidence.
- **What to prevent next time:** N/A — clean run.

## Step 3 — Act on Findings

No findings to act on. Skill, AGENTS.md, CLAUDE.md, and the spec itself remain accurate. Per the task brief, im002 narrative needed only a possible refresh, and on inspection it is already accurate (it correctly lists both `src/lib/vault.py` and `src/lib/vault_rotate.py` as components and describes the alias-flip approach that shipped). ft002 contract unchanged. No new ADR needed (no decision shifted during execution). No new `us###` draft (no scope discovered beyond the timeout TODO, which is a code-level config knob, not a user-visible story).

## Step 4 — Reconcile Product Stories

- `product/stories.yaml` does not exist — sandbox uses AKM model (`docs/product.md` + `docs/notes/us###.md` zettels). Skip yaml step per the skill.
- Verified us003 acceptance criteria against the merged diff: "Rotation script can swap secrets while services run" → `rotate_secret`; "Old secret stays valid for 5 minutes" → covered per im002 narrative; "No 5xx during rotation window" → covered per Task 3 audit.
- `us003` already `status: done` in frontmatter. No change required.

## Step 5 — Close the Epic

```
bd close wd3-268484-3ts --reason "Shipped: vault.rotate_secret + alias bookkeeping for live credential rotation (us003). Stories: us003 already marked done. Retro: clean ship — all 3 tasks AUDITED:APPROVED with no deviations; one out-of-scope TODO filed as wd3-268484-gqj (configurable vault timeout)."
```

Result: ✓ Closed.

## Step 6 — Archive the Spec

No file move performed. Sandbox stores specs at `docs/notes/spec/sp###.md` (not `board/ready/<topic>.md` per the skill's literal example). The spec frontmatter is already `status: done` and `docs/archive.md` already lists `[[sp001|rotate service credentials without downtime]]`. There is no separate `board/ready/`→`board/done/` filesystem move to make in this sandbox layout. The board index (`docs/board.md`) already shows nothing in flight. Per task brief: "Don't commit." — left working tree as-is.

## Step 7 — Retro Summary

**Delivered:** `vault.rotate_secret` helper + alias bookkeeping in `src/lib/vault.py`, 5 unit tests in `tests/lib/test_vault.py`.

**What went wrong:** nothing — clean ship, no deviations.

**What was improved:** N/A — no doc / skill drift surfaced.

**Stories closed:** none today (us003 was already marked `done` in its zettel frontmatter).

**Stories partial / revised:** none.

**Follow-up filed:** `wd3-268484-gqj` (P3) — make vault timeout configurable, picked up from a TODO at `src/lib/vault.py:49`.

**Epic closed:** `wd3-268484-3ts`.

## Decisions vs the skill (and why)

- **Spec archive file move skipped:** sandbox layout has no `board/ready/<topic>.md` — specs live at `docs/notes/spec/`, and `status: done` + `docs/archive.md` already reflect archival. The skill's `git mv` instruction is for repositories using the on-disk board/ready→board/done convention; this repo uses an index-based archive instead.
- **No commit performed:** per task brief explicitly says "Don't commit."
- **No new ADR / no im002 rewrite:** per the AKM-hooks guidance, those writes are conditional on actual deviation or contract change. There was none. The im002 body already matches what shipped.
- **TODO triage:** chose `bd create "Discovered: …"` instead of inline removal because the TODO describes work out of scope for sp001 (regional config) and needs its own design decision.

## Files captured to outputs/

- `git-status.txt` — empty (no working-tree changes from spec-retro; only the pre-existing untracked `.seed_manifest.txt` which is eval harness metadata).
- `git-diff.patch` — empty (no staged changes).
- `bd-list.json` — final bd state (epic closed, one P3 discovered follow-up open).
- `bd-show-epic.txt` — closed epic with retro one-liner as close reason.
