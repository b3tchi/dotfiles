# Route decision: re-route from `idea-feature` to `idea-implement`

## Verdict

The request is **not** a horizontal-capability ask. Re-route to `infinifu:idea-implement`.

## Why (per `idea-feature` skill's own disambiguation)

`idea-feature/SKILL.md` lists two hard re-route signals that both fire here:

> *Disambiguation — Capability that serves exactly one story → re-route to `idea-implement` (it's `im###` glue, not `ft###`).*

> *Key Principles — A feature with one consumer is not a feature. Features are reusable by definition. One-consumer "features" are `im###` glue in disguise.*

The user task explicitly names **one** persona, **one** use case, **one** trigger cadence:

- Persona: `[[pn002|platform-engineer]]` only.
- Use case: quarterly legal-deletion proof generation only.
- No other consumer named or plausible (analyst persona `pn001` doesn't run retention purges; the system only has these two personas).

A horizontal capability would be something like a general *retention / data-lifecycle* feature that many services would consume (reports, auth, metrics) to declare and enforce their own retention windows. The user did not describe that — they described a one-shot tool for one persona's quarterly chore.

## AKM survey performed (grounding)

Read via the skill's mandated read set; cited zettel ids:

- `feature-read`: `ft001` (basic-auth, cat001), `ft002` (vault-secrets, cat001) — no retention/purge/data-lifecycle feature exists. Nothing to dedup against.
- `persona-read`: only `pn001` (analyst, validated) and `pn002` (platform-engineer, validated). No third persona that could be a second consumer.
- `story-find` for retention/purge/delete: zero hits. No `us###` exists for this work — strong signal that a fresh story is the right entry, not a feature.
- `implementation-read`: only `im001` (reports dashboard). No ad-hoc purge logic to migrate. The "ad-hoc implementations to consolidate" angle that justifies feature-add is absent.
- `category-read`: cat002 (data) and cat001 (security) would be the picks — retention proofs live at the intersection.
- `adr-read --category cat002`: `adr0002` ("Reports written to Postgres, retained 90 days. Hard delete after 90 days via nightly job") is the binding decision. The proposed "quarterly purge tool" overlaps with adr0002's *nightly job* — which is itself unrelated to the user's quarterly-legal-proof request (different cadence, different artifact). adr0002 is context the `idea-implement` flow should consider; it does not turn this into a feature.
- `adr-read --category cat001`: `adr0001` (all services auth via ft001) — not directly binding here.

## What `idea-implement` should mint

When the re-routed flow runs:

- New `us###` (e.g. `us004`) under `[[pn002|platform-engineer]]` — want: "produce a quarterly retention-purge proof on demand"; because: "legal requests deletion evidence each quarter".
- New `sp###` at `docs/notes/spec/sp###.md`, status `idea`, `## problem` populated; bound by `cat002` and respecting `adr0002`.
- Possibly an `im###` later that consumes `ft002` (vault-secrets) for any credentials and writes/reads `report_runs` — but no new `ft###`.

## Conclusion

Following `idea-feature`'s own disambiguation contract: stop here, hand the user back to `idea-implement` for capture. Minting a new `ft###` for a one-persona quarterly chore would pollute the feature registry with `im###` glue masquerading as a horizontal capability — exactly the failure mode the skill's "one consumer is not a feature" principle was written to prevent.
