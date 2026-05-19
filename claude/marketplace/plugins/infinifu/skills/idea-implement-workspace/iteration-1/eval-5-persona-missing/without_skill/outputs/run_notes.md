# Run notes — eval-5-persona-missing, without_skill

## Task
Move `us005` (quarterly audit-log export, status: draft) forward as if
running `infinifu:idea-implement`. The skill itself was unavailable, so
I drove the AKM lifecycle manually using `docs/notes/akm.md` as the
spec for shapes and lifecycle.

## Diagnosis on read-through

- `us005.role` linked to `[[pn999|compliance-officer]]` — **pn999 does
  not exist**. Only `pn001` (analyst) and `pn002` (platform-engineer)
  were seeded. This is the deliberate gap the eval name flags.
- Acceptance criteria on `us005` were already concrete (CSV of
  quarter's hard-deletes, with table/PK/timestamp/job-id, signed by a
  vault key). No refinement needed before promoting to `ready`.
- Available features: `ft001` basic-auth, `ft002` vault-secrets. No
  audit-log primitive. `adr0002` (90-day retention via nightly job) is
  the *source* of the deletions this story has to evidence; `adr0003`
  (no SMTP relay) means delivery of the artefact will be out-of-band
  for the first quarter.
- `docs/product.md` was already incomplete vs the seed (missing us004,
  adr0003, cat004). I did not back-fill the pre-existing gaps; I only
  added entries for the zettels I introduced.

## What I did

1. **Created `pn003` Compliance Officer** (status: draft, with three
   open_questions for the auth path, on-demand vs scheduled, and
   export retention). This unblocks `us005.role`.
2. **Flipped `us005` to status: ready** and re-pointed `role` from
   `[[pn999|compliance-officer]]` → `[[pn003|compliance-officer]]`.
3. **Created `ft003` audit-log** (status: proposed) — an append-only
   `audit_deletions` ledger plus a `record_deletion()` helper and an
   `export_quarter()` signed-CSV helper. Made it a Feature rather
   than baking it into the reports service because the same primitive
   should serve future destructive-event compliance asks (secret
   revocation, account purges).
4. **Created `im002`** (status: proposed) — implementation card
   solving `us005`, consuming `ft003` + `ft002` + `ft001`. Approach:
   wire the existing 90-day retention job to write one
   `audit_deletions` row per hard-delete, then add a
   `reports audit-export <quarter>` CLI in the reports service that
   selects the trailing quarter, writes CSV, detached-signs with a
   vault-managed key.
5. **Created `sp001`** at `idea` stage in `docs/notes/spec/sp001.md`
   with `## problem` populated. `## solution` / `## plan` / `## tasks`
   left as placeholders — those belong to spec-writing /
   spec-refinement, not idea-implement.
6. **Updated `docs/product.md`** to register `pn003`, `us005 >>
   im002`, `ft003`, and `cat004` in the Categories chain.
7. **Updated `docs/board.md`** to list `sp001` under `## idea`.

## Open questions / handoff
- The compliance-officer auth path: do they get a real basic-auth
  account (adr0001) or do platform engineers run the export on their
  behalf? Captured as the first `open_questions` bullet on `pn003`
  and as the first scope-exclusion in `sp001.problem`.
- adr0003 says no shared notification layer — for the first quarter
  the signed CSV is handed over out-of-band. If that proves painful,
  it's the natural seed for a future `ft###` notification/delivery
  feature.
- `us004` (search reports somehow) has uselessly thin acceptance
  criteria but is out of scope here. Left as-is.

## Files

New:
- `docs/notes/pn003.md`
- `docs/notes/ft003.md`
- `docs/notes/im002.md`
- `docs/notes/spec/sp001.md`

Modified:
- `docs/notes/us005.md` — role link, status draft → ready
- `docs/product.md` — registered pn003 / us005 / ft003 / cat004
- `docs/board.md` — sp001 under `## idea`
