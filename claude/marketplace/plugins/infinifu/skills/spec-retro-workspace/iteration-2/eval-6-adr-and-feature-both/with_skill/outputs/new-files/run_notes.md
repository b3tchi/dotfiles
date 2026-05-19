# Retro run notes — sp001 (eval-6: ADR + Feature both)

## Inputs read

- `git log --oneline` → two commits:
  - `a15583b` — initial sp001 ship (rotate_secret + alias bookkeeping)
  - `8ce8d2f` — decision-shift commit adding `src/lib/vault_transit.py`
- `bd show wd6-1266658-8wq.1` task note recorded **two** distinct findings:
  1. **DECISION SHIFT** — adopted Vault Transit over KV. Vendor/paradigm
     trade-off: deterministic versioned key rotation as a first-class
     primitive vs lock-in to HashiCorp Vault. Cross-cutting (every future
     encrypted-rotation flow lands here).
  2. **CAPABILITY** — `src/lib/vault_transit.py` shipped as a thin reusable
     wrapper. Concrete API (`encrypt` / `decrypt` / `rotate_key`), zero
     domain logic, named next consumers (metrics alerting signing keys,
     reports signed-URL flow).
- Shipped diff confirmed both: the second commit added only the wrapper
  file; the first carried `rotate_secret` + lock map. No KV-related code
  in the final tree.
- Spec sp001 at `status: done`, archived under `docs/archive.md ## done`.
  Board entries already removed. Preconditions for spec-retro satisfied.

## Classification (per Key Principle "ADR vs Feature — Both" row)

The eval-6 prompt deliberately presents the "Both" row of the
discriminator table from `spec-retro/SKILL.md`:

> Both a strategic choice *and* the capability it produced → **one of each**
> — ADR records the decision, Feature records the surface.

Applied:

- **Strategic test** — "Could a future engineer choose this differently?"
  Yes. They could pick a non-Vault backend, accept the KV trade-off, or
  build a custom rotation primitive. Therefore the choice belongs in an
  ADR. Vendor lock-in is explicitly a foreclosed-alternative signal.
- **Reuse test** — "Could a future engineer reuse this?" Yes. The wrapper
  has two concretely-named next consumers (metrics alerting, reports
  signed URLs). That's not speculative — it's the "two+ real consumers"
  signal in the Feature-extraction table. Plus it ships with a concrete
  api_surface, data_model is "none local", components is named — every
  Feature-card section is fillable. Therefore the surface belongs in a
  Feature.

Both → one ADR + one Feature, referencing the same execution event but
recording separate concerns.

## Write order (per skill checklist step 10: ADRs first → ft → im → us → product)

1. **`adr0004`** minted — `Vault Transit secrets engine over plain KV for
   credential rotation`. Status: `Accepted`. Category `[[cat003]]`
   (infrastructure). Context section captures the KV vs Transit trade-off
   table; consequences section is honest about lock-in to HashiCorp,
   Transit availability dependency, and the foreclosed "non-Vault store"
   option from the original `sp001` plan.

2. **`ft003`** minted — `vault-transit-wrapper`. Status: `stable`.
   Category `[[cat003]]`. Chose to mint a *new* feature rather than widen
   `ft002` because `ft002` is named "vault-secrets" and scoped to the
   plain `secret(name)` KV read path; Transit primitives are a different
   surface (encrypted rotation, not retrieval) and consumers will import
   from `acme.lib.vault_transit`, not `acme.lib.vault`. `ft003` declares
   the dependency on `ft002` for connectivity and binds `adr0004`. The
   `## consumers` block carries the two named next consumers from the
   bd task note plus the current `im002`.

3. **`im002`** rewritten — `## approach` now narrates the in-flight shift
   from KV to Transit and points at `adr0004`. `## features` now lists
   both `ft002` (read path) and `ft003` (rotation primitives). `## components`
   now lists `vault_transit.py` alongside `vault.py` / `vault_rotate.py`.
   `## api_surface` documents the three actual surfaces. New `## binds`
   block lists the ADRs the implementation respects, including `adr0004`.

4. **`us003`** — no new follow-up stories drafted (the wrapper covers its
   named scope; the metrics / reports consumer work belongs to those
   services' own backlogs, not this retro).

5. **`docs/product.md`** updated — `us003` bullet now carries
   `>> [[im002]]`. `ft003` added to the Features list. New
   `### [[cat003|infrastructure]]` ADR group registers both `adr0003`
   (previously orphaned in the product hub) and the new `adr0004`.

## Bd epic close

Reason: "Retro sp001: rotate_secret + Transit wrapper shipped. Rewrote
im002 to reference Transit. Minted adr0004 (Vault Transit over KV —
vendor/paradigm lock-in to HashiCorp) and ft003 (vault-transit-wrapper —
encrypt/decrypt/rotate_key surface, named next consumers: metrics
alerting, reports signed-URL)."

## Out-of-scope checks

- No status flips touched (work-merge did them — verified `im002` at
  `accepted`, `us003` at `done`, `sp001` at `done`).
- No board / archive edits (work-merge did them — verified archive shows
  sp001 under `## done`, board has no `## ready` entries).
- No tests run (work-merge gated that already).
- No silent feature-extraction beyond `ft003` — the Transit wrapper meets
  the "two+ named consumers" bar; no other candidates surfaced from the
  shipped diff.
