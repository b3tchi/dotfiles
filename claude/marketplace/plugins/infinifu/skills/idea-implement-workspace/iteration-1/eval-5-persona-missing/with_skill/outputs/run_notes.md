# Run notes — eval-5-persona-missing / with_skill

## Persona check

Story `us005` referenced `[[pn999|compliance-officer]]` in its `## role`
section. Inspection of `docs/notes/` showed only `pn001.md` (analyst) and
`pn002.md` (platform-engineer) — no `pn999.md` existed. The
`idea-implement` skill's step 4 requires resolving `## role` to a real
`pn###`, and if missing, minting via `persona-write` before continuing
(sub-loop). The id `pn999` was clearly a placeholder seeded into the
sandbox; the canonical next id by the persona-write rule (max + 1, no
gap reuse) is `pn003`.

## Option taken

**Option (a)** — mint `pn003` (compliance-officer) directly using the
`persona-write` schema conventions, then continue the `idea-implement`
loop end-to-end.

Rationale: the user said to make the reasonable call without stopping
for clarifying questions. The `pn999` literal is plainly an unseeded
placeholder, the canonical alias is already supplied by the story
(`compliance-officer`), and stopping at the gate (option b) or re-
routing (option c) would have produced strictly less work product
without preserving any information the user couldn't reconstruct.
Option (a) preserves AKM invariants: a real `pn003.md` now exists,
`us005` no longer carries a dangling wikilink, and the lifecycle
contract for `idea-implement` (us draft → ready + sp### with `##
problem` referencing surveyed ids) is satisfied.

## What got written / changed

**New files**

- `docs/notes/pn003.md` — Persona zettel. Canonical alias
  `compliance-officer`. Status `draft` because three open questions
  remain (which regulation drives the cadence; internal vs external
  auditor consumption; UI vs CLI vs scheduled-job surface). Schema
  per `akm.md#persona--pnmd` and `persona-write` quick reference:
  `# Persona [[product]]` H1, sections in the order `## name` /
  `## summary` / `## primary_goals` / `## open_questions`, footer
  `Index: [[product]]`.
- `docs/notes/spec/sp001.md` — Spec zettel at status `idea`. H1
  `# Spec [[cat001]] [[cat002]] [[board]]`. `## solves [[us005]]`
  back-link. `## problem` populated with wikilinks to every relevant
  surveyed id per the reference-discipline rule:
  - `[[us005]]` — source story
  - `[[pn003]]` — persona
  - `[[cat001]]` security + `[[cat002]]` data — taxonomy picks
  - `[[adr0001]]` — auth binding from category-survey
  - `[[adr0002]]` — Postgres retention binding from category-survey
  - `[[ft001]]` basic-auth + `[[ft002]]` vault-secrets — candidate
    feature consumers (binding deferred to spec-writing, per the
    skill's "feature consumption is candidacy" principle).

**Modified files**

- `docs/notes/us005.md` — two edits: `[[pn999|compliance-officer]]` →
  `[[pn003|compliance-officer]]` (resolves dangling link), and
  `status: draft` → `status: ready` (AC are testable as-written: CSV
  of trailing-quarter hard-deletes with deletion-timestamp / table /
  primary-key / job-id, signed with a vault-managed key). No body
  invention.
- `docs/board.md` — added `[[sp001|quarterly audit-log export]]` under
  `## idea`. Updated the intro paragraph from "Nothing in flight" to
  reflect the one in-flight spec.
- `docs/product.md` — added `### [[pn003|compliance-officer]]` section
  under `## Stories` with `[[us005|quarterly audit-log export]]`
  listed beneath it (matches the existing pattern for `pn001` /
  `pn002`).

## Skill-rule observations

- The `persona-write` skill's `critical_rules` say "Don't touch the
  hub — `docs/product.md` only changes when a story references this
  persona; that's `infinifu:story-write`'s job." In this run the
  persona-mint sub-loop and the story re-emission (`us005` draft →
  ready) happened together, so the hub update is owned by the story
  side, not the persona side. I added the new `### pn003` heading to
  the hub *because* us005 now references pn003 and is being
  promoted — consistent with both skills' rules.
- The story `us005` already had testable AC at draft state, so the
  AC-gate did not block. The `idea-implement` skill flags this case
  in step 5 (no need to ask the user for testable AC).
- No bd / epic creation here — that lives downstream at
  `spec-ready`. The spec is at `idea` status, not `ready`.

## Not committed

Per instructions, files are staged but not committed. The
`.seed_manifest.txt` was unstaged (seed artifact, not skill output).
