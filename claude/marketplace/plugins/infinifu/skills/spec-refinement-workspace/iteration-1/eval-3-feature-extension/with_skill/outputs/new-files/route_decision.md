# Route decision — sp001 spec-refinement (Feature-sanity surfaced extension)

## Decision

**Did NOT block.** Refinement proceeded, but the breakdown is **gated on
a Feature extension** — Task 1 of sp001 routes the user to
`infinifu:idea-extend` on `[[ft002]]` **before** Tasks 2–4 can ship.

## Why this is a Feature-extension, not a silent over-reach

Per `spec-refinement` Feature-sanity rule:

> Re-read the Feature's `## providing` paragraph. If the spec uses the
> feature in a way that isn't in `## providing`, that's a *Feature
> extension* — call it out as a separate task that goes through
> `idea-extend` on that `ft###` first.

sp001's `## solution` body contains an "Implementation detail" addendum
that calls into two ft002 surfaces that ft002 does **not** currently
provide:

| Call site in sp001 | ft002 today | Verdict |
|---|---|---|
| `vault.set_default_ttl(seconds=300)` once at boot | `## api_surface` exposes only `secret(name)`; no ttl helper | **Extension required** |
| "emit structured audit records via [[ft002]]'s audit-log channel" | `## providing` says "Vault-backed secret retrieval"; `## data_model: None local`; no audit channel | **Extension required** |

ft002 status is `stable`. Features are append-only in spirit (per
`docs/notes/akm.md`): "Tighten the `providing` / `api_surface` contract
only when reality demands; widening means a new Feature" — widening is
exactly what's happening here, and it goes through `idea-extend`.

## Why this is a hard gate, not a "we'll discover it during work"

If Tasks 2–4 ship without the extension:

- `vault.py` either calls a `set_default_ttl` that doesn't exist in
  ft002 (test fails / runtime ImportError) **or** reaches around
  ft002's contract by talking to the vault SDK directly — silently
  forking the platform's vault story. Both are Feature-contract
  violations and the #1 source of post-merge rework that the
  spec-refinement skill exists to prevent.
- The audit-log channel becomes a side-channel inside `vault.py`
  (e.g. `print()` masquerading as "logging"), which is a hidden
  Feature-extension that the next consumer copies and the AKM graph
  loses sight of. The skill's "anti-patterns" section explicitly calls
  this out.

## What the user sees

- `docs/notes/spec/sp001.md` now contains the SRE-passed `## plan` +
  `## tasks` blocks. The breakdown is **not** approved-and-ready — it's
  the breakdown that the user reviews per the skill's design-approval
  gate.
- **Task 1** is "Route ft002 extension through idea-extend". It has zero
  source files in `files_touched`, 2h effort, and its success criterion
  is "a new `sp###` exists at `status: idea` whose `## problem` names
  the two ft002 surface additions". This routes the user out of
  spec-refinement and into `infinifu:idea-extend` for ft002.
- Tasks 2, 3, 4 all carry `depends: Task 1` so the dependency is
  machine-readable when `spec-ready` later writes bd ids.
- `docs/notes/im002.md` `## specs` back-link is finalized (skill's
  graph-closure deliverable).
- `docs/board.md` is **unchanged** — sp001 stays at `status: spec` per
  the skill's "Out of scope" rule (board moves happen at `spec-ready`).

## Two pivot paths if the user does NOT want to extend ft002

Documented in Task 1's `#### edge_cases`:

1. **Drop the audit-log requirement** from sp001's `## solution` and
   **hard-code the 300-second overlap** inside `rotate_secret` instead
   of calling `set_default_ttl` globally. That pivot rewrites sp001's
   `## solution` and the spec re-enters `spec-writing` →
   `spec-refinement`.
2. **Mint a new ft### entirely** for the rotation telemetry (instead of
   widening ft002). Same downstream consequence — sp001's `## solution`
   needs a rewrite before the breakdown stands.

Either way, the call is the user's, not the skill's. The skill's job is
to surface the conflict at refinement time, not silently bake it into
the task list.

## Alignment with skill's own rules

- "Feature surface, not feature intent. Tasks must call `## api_surface`
  exactly. If the spec needs functionality outside the Feature's
  `## providing`, that's a Feature extension via `idea-extend`, not a
  silent over-reach in the task list." → applied.
- "Surface as design-approval gate to the user — the breakdown is a
  commitment, not a proposal." → sp001 is now in the user's hands for
  approval, gated on Task 1.
- "Does NOT use bd, NOT promote status, NOT touch the board" → confirmed:
  sp001.status stays `spec`, board.md untouched, no bd activity.
