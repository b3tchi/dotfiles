# Route decision — dedup hit on existing feature

**Skill:** `infinifu:idea-feature` (entry type: *feature add*, AKM
lifecycle stage 1).

**Outcome:** Dedup gate tripped at step 1 of the entry-specific
checklist. Stopping here per skill contract — "Close match → re-route
to `idea-extend` on that `ft###` and stop."

## Request

> Services keep shelling out to the vault CLI ad-hoc to fetch DB
> credentials and API tokens at startup. We need a shared
> secrets-retrieval capability — a single library every service calls
> instead of pasting vault shell-outs everywhere.

## Dedup check (step 1)

Filtered `feature-read` against keywords *secret*, *credential*,
*vault*, *token*. One existing feature matches the capability
boundary directly.

### Match: [[ft002|vault-secrets]] (status: stable)

From `docs/notes/ft002.md`:

- `## providing` — "Vault-backed secret retrieval. Every service calls
  `secret(name)` to read credentials at runtime."
- `## api_surface` — `from acme.lib.vault import secret`; `db_url =
  secret("reports/db_url")`.
- `## components` — `src/lib/vault.py`.
- `## data_model` — "None local. Vault is the source of truth."

The ask ("one library every service calls instead of shelling out to
the vault CLI") is exactly [[ft002]]'s providing contract. The
capability already exists, is `stable`, and ships the canonical client
at `src/lib/vault.py`.

## Why this is **not** a new `ft###`

- **`providing` collision.** Both the request and [[ft002]] describe a
  single shared secret-retrieval library. Minting a second `ft###`
  would split the registry and create two clients to maintain — the
  exact rot the feature schema's single-`providing` invariant exists
  to prevent.
- **`api_surface` collision.** Any new feature would land a
  `secret(name)`-shaped call, identical to [[ft002]]'s.
- **Symptom is adoption, not capability.** Services still shelling out
  to the vault CLI means [[ft002]] is under-consumed, not missing.
  That is a migration / enforcement problem on existing implementations
  (and possibly a gap in [[ft002]]'s api_surface that makes the CLI
  shell-out look easier), not a new horizontal building block.
- **A feature with one consumer is not a feature** (skill key
  principle). The inverse also holds: a feature whose problem is "more
  consumers should use it" is an extension of the existing feature,
  not a sibling.

## Re-route

Use `infinifu:idea-extend` framed against [[ft002]]. The extension
brainstorm should explore:

- Whether [[ft002]]'s `api_surface` has gaps that nudge services
  toward the vault CLI (e.g. startup-time credentials, batch fetch,
  retry-on-vault-restart semantics, caching, structured config
  bootstrap).
- Migration story for the ad-hoc CLI shell-outs currently in services
  — these are candidate `im###` migration targets and should be
  surfaced via `implementation-read` against keywords *vault*,
  *secret*, *credential* during the extend brainstorm. No existing
  `im###` in the sandbox carries the ad-hoc pattern as a documented
  card; the extend skill will need to either inventory them from
  source or accept that the migration target list is "every service
  that imports from a vault CLI invocation."
- Whether the change widens [[ft002]]'s contract (new `api_surface`
  rows) or just clarifies / documents existing semantics. Widening
  may push toward an [[ft002]] supersession chain per the AKM
  append-only discipline.
- Constraints inherited from [[cat001|security]] (the H1 category on
  [[ft002]]) and [[adr0001]] (which already mandates [[ft001]] for
  auth — secrets retrieval is the analogous mandate for credentials,
  and an ADR may be warranted *if* the extend produces a new
  contract).

## Halt point

Stopping per the skill rule. No `sp###` minted, no [[board]] edit, no
further AKM survey done — re-routing is the correct exit and the
extend skill owns the continuation.
