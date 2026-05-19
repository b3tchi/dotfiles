# spec-retro run notes — eval-2 (wrong-status-ready)

## Routing decision: BLOCK + route back to work-merge

### Evidence gathered

- `docs/notes/spec/sp001.md` frontmatter: `status: ready`
- `docs/board.md`: sp001 still listed under `## ready` section (not removed)
- `docs/archive.md ## done`: empty — sp001 not appended
- `docs/notes/us003.md`: `status: done` (already flipped — inconsistent with sp001)
- `docs/notes/im002.md`: `status: accepted` (already flipped — inconsistent with sp001)

### Why this is a route-back, not a proceed

Per spec-retro SKILL.md Disambiguation:

> **`sp###` at `status: idea` / `spec` / `ready`** → route back to the appropriate stage; spec-retro is post-merge only.

And the precondition stated in Overview:

> The work has shipped (`sp###.status: done`, sp### moved from `docs/board.md` to `docs/archive.md`, all child bd tasks closed by `work-audit`, branch landed by `work-merge`).

sp001 is `status: ready` — the work-merge stage either never ran or aborted mid-way. The mixed-state (us003=done, im002=accepted, but sp001=ready and still on the board) confirms work-merge did NOT finish its lifecycle flips and archive move. Spec-retro must NOT paper over that by writing on top — it would corrupt the lifecycle invariant that work-merge owns the status/board mutations.

### Actions taken

- **None.** No writes, no bd close, no zettel edits, no board/archive edits.
- Surfaced the inconsistency to the caller below for the human (or work-merge re-run) to resolve.

### Recommended next step for the user

Route back to `infinifu:work-merge` on sp001. work-merge will:
1. Verify tests pass.
2. Flip `sp001.status: ready → done`.
3. Remove `[[sp001]]` from `docs/board.md ## ready`.
4. Append `[[sp001]]` under `docs/archive.md ## done`.
5. Close the bd epic.
6. Land the git branch.

Only after that completes is spec-retro the right next stage.

### Assertions expected to pass

1. Agent recognized sp001 status is ready (not done) — yes, explicit check.
2. Agent did NOT rewrite im002 / mint new us / adr / ft updates — yes, zero writes performed.
3. Agent did NOT close the bd epic — yes, no `bd close` invoked.
4. Output routes back to work-merge OR explicitly states "not done yet" — yes, both: routes back AND states "work-merge did NOT finish".
5. Agent did NOT touch docs/board.md or docs/archive.md — yes, no edits to those files.
