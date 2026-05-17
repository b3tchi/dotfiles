# Run notes — eval-4 dedup-existing-feature (without_skill)

## Task
Use `infinifu:idea-feature` to scope a "shared secrets-retrieval capability"
that would dedupe ad-hoc vault CLI shell-outs. Skill was unavailable;
worked from the AKM schema in `docs/notes/akm.md` directly.

## Key finding — request is a duplicate
[[ft002 vault-secrets]] already exists, `status: stable`, with exactly
the requested API:

```python
from acme.lib.vault import secret
db_url = secret("reports/db_url")
```

Components: `src/lib/vault.py`. Created 2026-03-20, predates the request.

Source-code stubs in `src/services/*` advertise email/smtplib
duplication, not vault CLI shell-outs — no concrete evidence in the
sandbox that the problem-as-described actually exists.

## Artifacts produced

1. **`docs/notes/spec/sp001.md` (new)** — idea-stage spec capturing:
   - the original request,
   - the feature survey showing ft002 already covers it,
   - three options (adopt ft002 / extend ft002 / supersede ft002) with
     adoption as the recommended default,
   - exit criteria for moving from `idea` → `spec` (need real evidence
     of the shell-outs, otherwise the spec auto-dies).

2. **`docs/board.md` (modified)** — listed sp001 under `## idea`.

## What was deliberately NOT done

- No new `ft###` zettel. Minting one would have duplicated ft002 and
  violated the AKM "features are append-only, widen don't fork" rule.
- No ADR. No decision yet — this is still at the problem-framing stage.
- No `us###` story. Story-per-laggard-service comes later, only if
  concrete shell-out evidence surfaces.
- No code changes. Idea stage is documentation-only per AKM lifecycle.

## Behavior notes (without the skill)
Without the skill loaded I still surveyed existing features before
proposing a new one, which is the core guardrail the skill enforces.
The output structure is hand-rolled against the AKM spec schema
(`## problem` only, no `## solution`/`## plan`) since this is `idea`
stage. A real `idea-feature` skill run would likely have produced a
similar conclusion but with stricter one-question-at-a-time cadence
and an explicit hard-gate dialogue before writing the file.
