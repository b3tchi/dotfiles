# Run Notes — spec-ready / eval-3 / already-annotated-stop / with_skill

## Outcome

**Skill behaved correctly: it stopped before mutating anything.**

The spec `sp001` already carries `#### bd <id>` annotations on every
`### Task N` block, which is the exact precondition the skill's step 4 and
Disambiguation rule "tasks already carry `#### bd` annotations → spec has been
processed before" requires it to refuse.

Wrote `<sandbox>/route_decision.md` explaining the verdict and the two routing
exits the skill names (close the matter / hand off to `work-do`).

## Detection path through the skill

1. Read SKILL.md — internalized: step 4 = no `#### bd` lines must exist.
2. Read `docs/notes/akm.md` — confirmed the Spec schema's `#### bd` H4 is the
   "attached by spec-ready" marker.
3. Read `docs/board.md` — `[[sp001]]` listed under `## spec` (consistent with
   `status: spec`; not yet on `## ready`).
4. Read `docs/notes/spec/sp001.md`:
   - Frontmatter: `status: spec` (passes step 2 gate).
   - `## tasks` block has three `### Task N` H3s (1, 2, 3).
   - **Every** task already carries `#### bd` with values `bd-001`, `bd-002`,
     `bd-003`. Step 4 fails.
5. Wrote `route_decision.md`, did not mutate anything else.

## Sandbox state vs. spec annotations

A diagnostic discovery worth noting (not required for the stop decision):

- The bd database in `.beads/` is **already seeded** with the matching
  epic + 3 child tasks:
  - `sandbox-nt2` — epic "Epic: rotate service credentials without downtime [sp001]"
  - `sandbox-nt2.1` — Add rotate_secret helper to vault.py
  - `sandbox-nt2.2` — Add vault_rotate orchestration module
  - `sandbox-nt2.3` — Synthetic-check hook for rotation window
- Dependency edges already present: `.2` blocks `.3`, `.1` blocks `.3`,
  parent-child links to `nt2`.
- The placeholder annotations in the spec (`bd-001`, `bd-002`, `bd-003`) **do
  not match** the real bd ids (`sandbox-nt2.1`, `.2`, `.3`).

This is informational only — the skill is correct to stop regardless of whether
the annotations are real or placeholder. The stop rule is purely "any `#### bd`
present blocks re-run." A human operator can decide whether to (a) reconcile
the annotations to the real ids and finish the half-done ready transition, or
(b) leave it and route to `work-do` with the real ids.

## Artifacts captured

- `git-status.txt` — sandbox git status (only `.seed_manifest.txt` and the new
  `route_decision.md` added; no mutations to docs).
- `git-diff.patch` — staged diff (just the route decision document and seed
  manifest; no edits to `sp001.md` or `board.md`).
- `bd-list.json` — full bd export showing the 4 pre-seeded issues, untouched.
- `new-files/route_decision.md` — the stop document itself.
- `modified-files/` — empty (no spec/board mutations).

## What the skill did not do (by design)

- No `bd create` → no duplicate epic / tasks.
- No `bd dep add` → no duplicate dependency edges.
- No edit to `sp001.md` → status stays `spec`; annotations untouched.
- No edit to `board.md` → bullet stays under `## spec`.
- No `bd init` (sandbox already has `.beads/`).
- No source-code changes.

## Verdict on the skill

Behavior matches the SKILL.md contract:

- Pre-flight check (step 4) correctly detects the "already processed" state.
- The skill exits cleanly without partial mutations.
- The route_decision artifact captures both possible follow-ups
  (close the matter, route to `work-do`) so a human can pick the right exit.
