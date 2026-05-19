# Run notes — eval-4 dedup-existing-feature (with_skill)

## Skill under eval

`infinifu:idea-feature` — direct entry skill for AKM lifecycle stage 1,
*feature add* entry type. Loads shared basics from
`infinifu:idea-brainstorming`.

## Task

User asked to scope a shared secrets-retrieval library (replacement
for ad-hoc vault CLI shell-outs across services) using
`infinifu:idea-feature`. Working dir: seeded Acme sandbox.

## Dedup check (step 1 of entry-specific checklist)

The seeded Acme sandbox already contains a feature with the exact
capability boundary:

- [[ft002]] `vault-secrets` — status `stable`, created 2026-03-20.
  - `## providing`: "Vault-backed secret retrieval. Every service
    calls `secret(name)` to read credentials at runtime."
  - `## api_surface`: `from acme.lib.vault import secret` →
    `secret("reports/db_url")`.
  - `## components`: `src/lib/vault.py`.

This is a direct hit on the user's ask ("a single library every
service calls instead of pasting vault shell-outs everywhere"). The
ft002 contract already promises exactly that. The actual symptom
(services shelling out to the vault CLI) is an **adoption / migration**
problem against ft002, not a missing capability.

## Decision

Per the skill checklist: *"Close match → re-route to `idea-extend` on
that `ft###` and stop."*

- Wrote `<sandbox>/route_decision.md` citing [[ft002|vault-secrets]] as
  the duplicate and naming `infinifu:idea-extend` as the correct
  sibling entry point.
- Did **not** mint an `sp###`.
- Did **not** edit `docs/board.md`.
- Did **not** run the rest of the AKM survey (consumers via `im###`,
  granularity check, category survey, ADR survey, migration sketch,
  sizing) — those belong inside the extend brainstorm now, not under
  this skill's contract.

## Reference discipline observed

Wikilinks in `route_decision.md`:

- [[ft002|vault-secrets]] — the dedup match.
- [[ft001]] — sibling feature used to anchor the security-category
  parallel (auth-mandate via [[adr0001]] vs the analogous
  credentials-mandate the extend may produce).
- [[adr0001]] — binding ADR under [[cat001|security]] that establishes
  the precedent for mandating a shared library.
- [[cat001|security]] — the H1 category currently on ft002, source of
  inherited constraints.
- [[im001]] — surfaced during survey as the lone existing
  Implementation card; it consumes [[ft001]] not [[ft002]], so it's
  not directly a migration target but confirms the sandbox has no
  documented vault-secrets consumer yet (which itself is signal for
  the extend skill — adoption work needs visible consumers).
- [[board]] — referenced as the hub that would have received the
  sp### entry if minting had proceeded.

## Gate reached

This is the dedup re-route gate (step 1 of the entry-specific
checklist), not the hard gate from `idea-brainstorming`. The task
instructions said "write `route_decision.md`" in the dedup branch and
"write `gate_reached.md`" in the proceed branch — only the route
decision file applies here.

## Files

- New: `route_decision.md` (in sandbox root, also copied to
  `outputs/new-files/`).
- Modified: none.
- `.seed_manifest.txt` shows up in `git status` because it was
  untracked in the seed; not authored by this skill execution.

## Skill behavior assessment (signal for skill eval)

- Skill description correctly triggered on "shared … capability —
  single library every service calls".
- The mandatory dedup-check step caught the duplicate before any
  brainstorming, AKM survey, or zettel minting happened — exactly
  the lifecycle-contract behavior the skill claims ("Stage-1 goals:
  problem-formulation + duplication-mitigation").
- The skill's explicit *Close match → re-route … and stop* rule made
  the halt unambiguous; no ambiguity about whether to also mint an
  sp### "just in case".
- Re-route target (`infinifu:idea-extend`) is the right sibling per
  the AKM lifecycle.
