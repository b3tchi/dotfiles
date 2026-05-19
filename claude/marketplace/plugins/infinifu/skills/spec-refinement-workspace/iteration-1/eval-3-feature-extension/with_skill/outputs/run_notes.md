# Run notes — eval-3-feature-extension / with_skill

## Task

Run `infinifu:spec-refinement` on `sp001` in the Acme sandbox. The
spec's `## solution` contained an "Implementation detail" addendum that
referenced two ft002 surfaces that ft002 does **not** provide:

1. `vault.set_default_ttl(seconds=300)` — ft002 `## api_surface`
   exposes only `secret(name)`.
2. "emit structured audit records via [[ft002]]'s audit-log channel" —
   ft002 `## providing` is "Vault-backed secret retrieval"; `## data_model`
   is `None local`; no audit channel anywhere.

Per the skill's Feature-sanity rule, this is a **Feature extension**,
not a silent use, and must be routed through `infinifu:idea-extend` on
[[ft002]] **before** any dependent task ships.

## Detection

Cross-referenced sp001's `## solution` body against ft002's body:

| sp001 call | ft002 surface | Mismatch |
|---|---|---|
| `vault.set_default_ttl(seconds=300)` | `## api_surface`: only `secret(name)` | Yes — function not in contract |
| ft002 "audit-log channel" | `## providing`: secret retrieval only; `## data_model: None local` | Yes — channel does not exist in feature |

ft002 is `status: stable`. AKM rule (akm.md L284-296): "Tighten the
`providing` / `api_surface` contract only when reality demands;
**widening means a new Feature**." Widening is what's happening here —
hence the `idea-extend` route on ft002 (the skill's documented path).

## Decision: did NOT block; included a gating Task 1

The skill offers two compliant responses:

1. Block and write `route_decision.md` only.
2. Include a Task that routes the user to `idea-extend` BEFORE
   dependent tasks.

I chose **option 2** (also wrote `route_decision.md` for traceability,
as the eval instructions allowed):

- **Task 1** in the refined sp001 is *Route ft002 extension through
  idea-extend (set_default_ttl + audit-log channel)*. 2h scoping-only
  effort, no source files in `files_touched`, success criterion =
  "a new `sp###` exists at `status: idea` whose `## problem` names the
  two ft002 surface additions".
- **Tasks 2, 3, 4** (implementing `rotate_secret`, wiring
  `set_default_ttl`, emitting audit records) all carry
  `depends: Task 1` so the dependency is machine-readable when
  `spec-ready` later writes bd ids.
- **Task 5** is the synthetic-check harness for zero-5xx (depends on
  Tasks 2+3).
- **Task 6** finalizes the `## specs` back-link on im002 (already
  applied in the edit; the task documents the deliverable for audit
  trail).
- Anti-patterns in `## plan` explicitly forbid ahead-of-extension
  shortcuts: no direct calls to undocumented ft002 helpers, no
  in-`vault.py` audit side-channel masquerading as logging.
- `route_decision.md` at sandbox root captures the full reasoning,
  the two pivot paths if the user rejects extending ft002 (drop the
  audit requirement / mint a new ft### instead), and the alignment
  with the skill's "design-approval gate" + "out of scope" rules.

## Skill discipline observed

- Status of sp001 stays at `spec`. Not promoted. (Skill: "NOT promote
  status".)
- `docs/board.md` untouched. (Skill: "NOT touch the board".)
- No `bd` commands run. (Skill: "Does NOT use bd".)
- `im002.md` `## specs` finalized with `[[sp001|...]]`. (Skill: "Finalize
  `## specs` back-link on the consumed `[[im###]]`".)
- SRE 8-category pass applied to all 6 tasks:
  - Granularity: all tasks ≤ 4h.
  - Implementability: explicit file paths, no "implement properly".
  - Success criteria: 3+ measurable per task; every task maps to a
    `us003.AC` line (named in the task body).
  - Dependencies: Task 1 gates 2-4; Task 5 depends on 2+3; Task 6
    depends on design-completion only. No cycles.
  - Safety: anti-patterns section in `## plan`; per-task edge cases
    cover concurrent rotation, vault outage, audit-channel outage,
    rapid re-rotation, idempotent ttl set.
  - Edge cases: explicit in every task.
  - Red flags: no `[detailed above]`, no `TODO`, no `[as specified]`.
  - Test meaningfulness: each test name describes the scenario; tests
    target real bug classes (silent phantom alias, race, vault
    outage rollback, off-by-one TTL boundary), not tautological
    "test_basic" coverage.
- ADR sanity: walked adr0001, adr0002, adr0003 — no decisions
  overturned, no supersession task needed. Captured under
  `## sanity-check notes`.
- Feature sanity: the blocking finding. Surfaced in
  `## sanity-check notes` and gated via Task 1 + `route_decision.md`.

## Files changed

| Path | Kind | Why |
|---|---|---|
| `docs/notes/spec/sp001.md` | modified | Appended `## plan`, `## tasks`, and `## sanity-check notes`. |
| `docs/notes/im002.md` | modified | Replaced `## specs - (none yet — …)` placeholder with `- [[sp001\|…]]`. |
| `route_decision.md` (sandbox root) | new | Records the Feature-extension call, the pivot paths, and skill-rule alignment for the user / reviewer. |
