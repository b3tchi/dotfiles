# spec-writing gate reached — BLOCKED at step 4 (AC check)

**Skill:** `infinifu:spec-writing`
**Target:** `sp001` — rotate service credentials without downtime
**Source story:** `us003`
**Gate:** Entry-specific checklist step 4 — "Re-read source us###.AC. If AC are vague or empty, block — route back to `idea-implement` (or `idea-extend`) for AC refinement."

## Pre-gate checks (passed)

1. **Target spec identified.** `docs/notes/spec/sp001.md` exists.
2. **Status verified.** Frontmatter `status: idea` — correct stage for spec-writing entry.
3. **Spec body read.** `## solves [[us003]]` present; `## problem` populated with context, candidate features (`[[ft002]]`), binding ADRs (`[[adr0001]]`, `[[adr0002]]`), and categories (`[[cat001]]`, `[[cat003]]`). No issue at this stage.

## Gate that blocked (step 4)

Re-read `docs/notes/us003.md` `## acceptance_criteria`:

```text
- it should work
- be fast enough
```

These are not testable criteria. They fail the gate:

- **"it should work"** — no observable behavior named. Work how, for whom, under what input? Cannot bind a solution shape to "works".
- **"be fast enough"** — no numeric target, no percentile, no measurement window. The spec's `## problem` already mentions a "5-minute overlap" and "zero 5xx" budget — those are real candidates for AC, but they live in the *spec* prose, not the *story* AC. The story is the contract; the spec cannot tighten what the story left vague.

The `## problem` section of `sp001` does name concrete targets (5-min overlap, zero 5xx during rotation), but per the AKM model and `spec-writing` Key Principles:

> **AC bind the solution.** A solution proposed against vague AC is a guess. The skill blocks at step 4 for exactly this reason.

The spec's `## solution` would otherwise be a guess — picking between `vault-rotate-policy`, `zero-downtime-swap`, and `blue-green-cred` patterns requires knowing whether the AC tolerates a brief 5xx, requires zero in-flight request loss, allows N seconds of dual-credential validity, etc. Without explicit AC the choice is not falsifiable.

## Route decision

**BLOCKED — do NOT write `## solution`.**

Route back to `infinifu:idea-extend` on `us003` to refine `## acceptance_criteria`. (Choosing `idea-extend` over `idea-implement` because `us003` already exists at `status: ready` — this is adjusting a captured story, not minting a new one.)

Suggested AC the user should confirm/refine in `idea-extend`:

- Rotation completes within X minutes end-to-end (numeric target).
- During rotation, old and new credentials both valid for a Y-minute overlap window (numeric).
- Zero 5xx attributable to the rotation across the overlap window (observable via service metrics).
- Rollback path: old credential remains valid for Z minutes after new credential is promoted, in case rotation must be reverted.
- Audit: every rotation event recorded with who/when/which service.

Once `us003.acceptance_criteria` is concrete and testable, re-run `spec-writing` on `sp001`. The pre-gate checks already pass; only step 4 is blocking.

## What was NOT done (and why)

- **No `## solution` written** to `sp001`. Premature against vague AC.
- **Frontmatter `status` not flipped** — stays `idea`.
- **`docs/board.md` not modified** — `sp001` stays under `## idea`.
- **No ADR / Feature dedup survey performed** (steps 5–8). These are downstream of step 4; running them would waste signal on AC that may shift after refinement.

## Files inspected (read-only)

- `docs/notes/spec/sp001.md` — status `idea`, problem populated, solution absent.
- `docs/notes/us003.md` — status `ready`, AC vague.
- `docs/product.md` — confirmed us003 is the platform-engineer story; ft001/ft002/adr0001/adr0002/cat001/cat003 all exist.
- `docs/board.md` — sp001 listed under `## idea`.
- `docs/notes/akm.md` — schema reference for the gate rule (story step 2: "If anything is vague, refine before moving on").
