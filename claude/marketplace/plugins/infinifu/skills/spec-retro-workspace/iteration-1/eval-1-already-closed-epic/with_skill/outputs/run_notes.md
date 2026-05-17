# Run notes — spec-retro on sp001 (already-closed-epic eval)

## Outcome

**NO-OP.** The retro had already completed in a prior run. Skill
correctly recognized the closed-epic state and did not re-execute
Steps 1-7.

## Decision walkthrough

1. **Invoked the skill.** Announced "I'm using the spec-retro skill to
   run the delivery retrospective." per the SKILL.md preamble.

2. **Validate Delivery (Step 1).** `bd list --parent wd1-263993-ijm
   --status open` → no children at all (all 3 tasks already closed).
   No untracked TODOs surfaced in source.

3. **Discovered the disambiguation case.** `bd show wd1-263993-ijm` →
   status CLOSED, close reason "Retro: prior run. im002 rewritten.
   Closed by previous spec-retro." This is **retro-shaped** per the
   skill's stated rule.

4. **Verified end-state matches a completed retro:**
   - sp001 frontmatter: `status: done` ✓
   - sp001 footer: `Index: [[archive]]` ✓ (correct per AKM lifecycle)
   - `docs/board.md` empty under all three lifecycle sections ✓
   - `docs/archive.md` lists sp001 under `## done` ✓
   - us003 frontmatter: `status: done` ✓
   - im002 frontmatter: `status: accepted`, body shape coherent ✓
   - Single ship commit in git log, no dangling work ✓

5. **Chose no-op over restore.** Restoring would mean re-opening a
   CLOSED epic and re-running steps whose targets are already in the
   post-retro state. That would destroy the audit trail of the
   original retro for zero net change. Restore is only appropriate
   when the close reason is *not* retro-shaped (e.g. "wontfix",
   "stale") — guarded against here by an explicit retro-shape reason.

6. **Wrote `<sandbox>/route_decision.md`** documenting the choice and
   evidence.

7. **Did not commit** (per task instructions). Did not mutate bd state.
   Did not edit im/ft/adr/us zettels.

## Captured outputs

| File | What |
|---|---|
| `git-status.txt` | Staged: `.seed_manifest.txt` (sandbox metadata), `route_decision.md` (required output). No other changes. |
| `git-diff.patch` | Contents of those two staged files. No AKM zettel touched. |
| `bd-list.json` | `[]` — no active issues (epic + tasks all closed). |
| `bd-show-epic.txt` | Full epic detail showing CLOSED status and retro-shaped close reason. |
| `route_decision.md` | Copy of the decision doc written to the sandbox root. |

## Skill behavior observations

**What the skill handled well:** the disambiguation rule is clearly
stated and the close-reason heuristic ("retro-shaped") is operational
— a human-readable string convention that survives the round-trip
through bd notes.

**What surfaced as friction:** the SKILL.md does not include an
explicit "Step 0: detect already-closed epic" branch. The
disambiguation rule lives in prose, not in the numbered process. An
agent following the steps strictly would hit Step 5 (`bd close`) and
either error out or silently re-close. Recommend lifting the
disambiguation into a Step 0 check at the top of "The Process".

**Other observation:** Step 6's `git mv ready/ → done/` is stale
relative to the current AKM model. In AKM, board-citizen specs live in
`docs/notes/spec/` regardless of lifecycle stage; lifecycle is carried
by frontmatter `status` and by hub membership (`board.md` vs
`archive.md`), not by directory location. The skill text still says
"`git mv <board>/ready/<topic>.md <board>/done/<topic>.md`" which
contradicts the AKM Spec lifecycle in `akm.md`. Worth a follow-up to
align the skill with the schema. (Not filed as a bd issue here because
the task says do not commit / do not mutate state.)
