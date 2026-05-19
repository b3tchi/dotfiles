# Run notes — without skill (baseline)

Task: take `us003` (rotate service credentials without downtime, status
`draft`) and walk it through what the `infinifu:idea-implement` skill
would do, so it ends up ready for spec-writing.

## What I did

1. Read `docs/notes/akm.md` to learn the AKM zettel schemas (Story,
   Implementation, Spec, Feature, ADR, Category) and the
   `## Process flow — implementing a Story` block.
2. Surveyed the workspace:
   - Story: `us003` already exists in draft, persona `pn002`
     (platform-engineer).
   - Features: `ft001` basic-auth, `ft002` vault-secrets — `ft002` is
     the obvious building block for rotation.
   - Categories: `cat001` security and `cat003` infrastructure fit
     the solution shape; `cat002` data and `cat004` observability are
     not central to this story.
   - ADRs: none directly bind the rotation approach; `adr0001` (auth
     unification) and `adr0002` (Postgres retention) are unrelated.
   - Board / archive are empty; no prior `sp###` or `im###` collisions.
3. Refined `us003`:
   - Flipped `status: draft → ready`.
   - Tightened `## because` (added SLA + off-hours motivation).
   - Expanded `## acceptance_criteria` from 3 loose bullets to 5
     testable ones (per-secret rotation, overlap window, synthetic
     check, operator UX, audit log).
4. Created `docs/notes/im002.md` — Implementation card,
   `status: proposed`, H1 `[[cat001]] [[cat003]]`, `solves [[us003]]`,
   consumes `[[ft002]]`. Captures the dual-version cache approach plus
   the new `vault_rotate.py` module + CLI.
5. Created `docs/notes/spec/sp001.md` — Spec, `status: idea`, H1
   `[[cat001]] [[cat003]] [[board]]`, with `## solves`,
   `## implements`, and a full `## problem` section. No `## solution`,
   `## plan`, or `## tasks` yet — those are spec-writing / refinement /
   ready stages.
6. Updated `docs/product.md` to annotate `us003` with `>> [[im002]]`.
7. Updated `docs/board.md` to list `sp001` under `## idea`.

## What I did NOT do

- No source code touched in `src/`.
- No bd epic/tasks (that's spec-ready territory).
- No new ADR (the rotation approach reuses an existing feature; no
  new architectural decision needs recording at this stage).
- No retro of `ft002` to widen its contract — that should fall out of
  spec-writing once the dual-version cache shape is committed to.

## Artifacts

New files:
- `docs/notes/im002.md`
- `docs/notes/spec/sp001.md`

Modified files:
- `docs/notes/us003.md` (draft → ready, criteria tightened)
- `docs/product.md` (added `>> [[im002]]` annotation)
- `docs/board.md` (added sp001 under idea)
