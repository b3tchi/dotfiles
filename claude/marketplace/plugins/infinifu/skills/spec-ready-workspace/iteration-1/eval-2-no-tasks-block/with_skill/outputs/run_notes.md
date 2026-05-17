# run_notes — spec-ready eval-2 (no-tasks-block)

## Setup applied

- Read skill: `claude/marketplace/plugins/infinifu/skills/spec-ready/SKILL.md`.
- Read AKM schema: `sandbox/docs/notes/akm.md`.
- Read board hub: `sandbox/docs/board.md` (sp001 listed under `## spec`).
- Read target spec: `sandbox/docs/notes/spec/sp001.md`.

## Disambiguation verdict

**Blocked. Route to `infinifu:spec-refinement`.**

The spec is at `status: spec`, which matches the *frontmatter*
precondition for spec-ready. But the body has only `## solves`,
`## implements`, `## problem`, `## solution` — no `## plan`, no
`## tasks`, no `### Task N` blocks. SKILL.md line 69 is explicit:

> `sp###` at `status: spec` but `## tasks` missing or incomplete →
> route to `spec-refinement`. spec-ready cannot invent tasks.

## What I did NOT do (deliberately)

The task brief says "Do NOT invent tasks" — that's also the skill's
own Key Principle ("Tasks come from `## tasks`, not from
invention"). Therefore:

- No `bd create` issued (no new epic, no new tasks).
- No `bd dep add` issued.
- `sandbox/docs/notes/spec/sp001.md` left unchanged — frontmatter
  status stays `spec`, body untouched, no `#### bd` annotations
  invented.
- `sandbox/docs/board.md` left unchanged — `[[sp001]]` stays under
  `## spec`, not promoted to `## ready`.

Only artifact created: `sandbox/route_decision.md` documenting the
block + the required next step.

## Unexpected finding — pre-seeded bd state

`bd list` shows the sandbox already contains a populated bd graph
that *looks like* a prior spec-ready run for sp001:

```
sandbox-nt2    epic  "Epic: rotate service credentials without downtime [sp001]"
sandbox-nt2.1  task  "Add rotate_secret helper to vault.py"
sandbox-nt2.2  task  "Add vault_rotate orchestration module"
sandbox-nt2.3  task  "Synthetic-check hook for rotation window"
```

This is **inconsistent with the spec file** — the spec has no
`## tasks` block and no `#### bd` annotations pointing at these
ids. Two possibilities:

1. The sandbox was seeded with bd state for a downstream skill
   (e.g. work-do) and the spec body just hasn't been refined to
   match — a seed-fidelity quirk, not a real conflict.
2. A prior spec-ready run minted these but the spec edits were
   reverted, leaving orphan bd entries.

Either way, the right move is still **route to spec-refinement**:
the spec body is the source of truth in AKM, and it currently
lacks `## plan` + `## tasks`. Whether the new tasks should
*reconcile with* or *replace* the pre-seeded bd ids is a question
for refinement to answer, not for spec-ready to silently paper
over.

If spec-ready had instead invented tasks here, it would have:

- Violated the skill contract (skipping the gate).
- Risked duplicating the pre-seeded epic + tasks (sandbox-nt2.*).
- Produced a `## tasks` block with no design rationale tying back
  to `## problem` / `## solution` / a refinement-grade `## plan`.

## Outputs captured

- `outputs/git-status.txt` — porcelain status: only
  `route_decision.md` and the pre-existing untracked
  `.seed_manifest.txt` are staged.
- `outputs/git-diff.patch` — staged diff (124 lines, mostly the
  route_decision body + seed manifest).
- `outputs/bd-list.json` — 4 pre-seeded entries (1 epic + 3
  tasks). No new ids added by this run.
- `outputs/new-files/route_decision.md` — copy of the block report
  written into the sandbox.
- `outputs/modified-files/` — empty (no spec or board edits made).

No commit issued.
