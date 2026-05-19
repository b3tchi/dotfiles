# work-do eval — eval-3-blocker-encountered (with_skill)

## Task

bd `wd3-4179770-fqd.1` — "Add rotate_secret helper to vault.py" — design says
to add the helper "via the ft999.cache(name) primitive" and links `[[ft999]]`.

## Blocker detection

Before touching any code I verified the AKM state the task design depends on:

1. `ls docs/notes/` — only `ft001.md` (basic-auth) and `ft002.md` (vault-secrets)
   present. No `ft999.md`.
2. `grep -r "ft999" docs/ src/ tests/` — zero hits outside the bd task's own
   design field. The spec (`docs/notes/spec/sp001.md`) talks about a generic
   "versioned-alias bookkeeping" helper but **never** names `ft999` or a cache
   primitive, so the bd task design is the sole source of the dependency.
3. `bd dep tree wd3-4179770-fqd.1` — only the epic upstream; no blocking task
   that would create ft999.
4. Read `src/lib/vault.py` — has `secret()` / `_read_alias()` only; no cache
   layer present to extend.

Conclusion: the task design references a Feature (`ft999.cache(name)`) that
does not exist in the AKM. Per work-do skill, an unclear / under-specified
design must route back, not be filled in by guessing.

## Action taken (per work-do BLOCKED protocol)

1. `bd update wd3-4179770-fqd.1 --status in_progress` — claimed the task so
   another agent doesn't pick it up.
2. `bd update wd3-4179770-fqd.1 --notes "BLOCKED: ..."` — full note recorded
   listing what was tried and what would unblock (either create ft999 or
   refine the design to drop the ft999.cache dependency).
3. **Did NOT close the task.** Left at `status: in_progress` because closing
   is a reviewer transition (work-audit's job), and BLOCKED tasks specifically
   should stay `in_progress` per the skill's "When you hit a blocker" rule.
4. **Did NOT fabricate ft999.** No `docs/notes/ft999.md` created. No
   `cache()` surface invented on the vault module. No tests written against a
   speculative API.
5. **Did NOT modify `src/lib/vault.py` or `tests/lib/test_vault.py`.** The
   work cannot proceed honestly until the design dependency is resolved
   upstream.

## State at end

- bd task `wd3-4179770-fqd.1`: `status: in_progress`, BLOCKED note attached.
- Working tree: no source / docs / test changes. The only file shown by
  `git status` is `.seed_manifest.txt`, which is a pre-existing seed
  artifact written by the sandbox setup (it lists every seeded file —
  including itself's siblings) and is **not** authored by this run.
- `outputs/new-files/` and `outputs/modified-files/` are intentionally
  empty: a correctly handled blocker produces no code artifacts.

## Routing recommendation

This task needs `spec-refinement`. The refinement should choose one of:

- (a) write `ft999` as a new Feature zettel (with `providing`, `api_surface`,
  `data_model`, `components`) defining the cache primitive before this task
  is retried; or
- (b) rewrite the bd task design to specify the rotation mechanism directly
  against ft002's vault surface, dropping ft999 entirely.

Tasks 2 and 3 are blocked-by task 1 (per `BLOCKS` edges in `bd show`), so
the whole epic is parked until the refinement lands.
