# Run notes — eval-2 (route to idea-implement, single-consumer)

## Skill under test
`infinifu:idea-feature` — loaded `SKILL.md` and the companion shared-basics skill `infinifu:idea-brainstorming`.

## Survey performed (AKM context)

Read every relevant zettel in `docs/notes/` before deciding:

- `docs/product.md`, `docs/board.md`, `docs/notes/akm.md` — workspace shape.
- Features: `ft001` (basic-auth, cat001), `ft002` (vault-secrets, cat001). **No retention / purge / data-lifecycle feature exists.**
- Personas: `pn001` (analyst, validated), `pn002` (platform-engineer, validated). Only two personas in the system.
- Stories: `us001` (dashboard, done, pn001), `us002` (date-range filter, ready, pn001), `us003` (credential rotation, ready, pn002). **No retention/purge story exists.**
- Implementations: only `im001` (reports dashboard). No ad-hoc purge logic to consolidate.
- Categories: cat001 security, cat002 data, cat003 infrastructure, cat004 observability.
- ADRs: `adr0001` (basic-auth, cat001), `adr0002` ("Reports written to Postgres, retained 90 days. Hard delete after 90 days via nightly job", cat002), `adr0003` (no SMTP relay, cat003). `adr0002` is the binding constraint for any retention work.
- README + `src/` tree: three services (`auth`, `metrics`, `reports`), shared `lib/`.

## Decision

**Re-routed to `idea-implement`.** Wrote `sandbox/route_decision.md`.

## Why

`idea-feature/SKILL.md` itself disambiguates this case directly:

1. *"Capability that serves exactly one story → re-route to `idea-implement` (it's `im###` glue, not `ft###`)."*
2. *"A feature with one consumer is not a feature."*

User task quote: *"only the platform-engineer persona uses it, and only once a quarter when legal asks for the deletion proof."* Explicit single-persona, single-trigger, single-purpose. No second consumer plausible — analysts do not run retention purges and the system has only those two personas.

The dedup check showed no existing feature to extend (so not `idea-extend`). The story for it doesn't exist yet (no `us###` covers retention proofs), so the right entry is `idea-implement`, which would mint:

- A new `us###` under `pn002` (platform-engineer) — "produce quarterly retention-purge proof on demand".
- A new `sp###` (status `idea`, `## problem` populated, H1 `[[cat002]] [[cat001]]`).
- Eventually an `im###` consuming `ft002` (vault-secrets) and respecting `adr0002`, but **no new `ft###`** — this is `im###` glue.

## Files written by this run

- `sandbox/route_decision.md` (new) — the re-route document.

No `sp###` minted, no `docs/board.md` mutation — both were skipped on purpose because the skill's own disambiguation contract said to stop and re-route before any zettel writes.

## Note on `.seed_manifest.txt`

`git status --porcelain` also shows `.seed_manifest.txt` as added. That file exists in the sandbox untracked from the seeding step; `git add -A` swept it in. It is not a product of this run — only `route_decision.md` was authored here.
