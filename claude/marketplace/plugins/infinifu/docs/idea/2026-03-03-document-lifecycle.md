# Document Lifecycle Management

## Problem

Infinifu skills produce documents (design docs, specs, plans) but there's no defined lifecycle for where they live, how they move between phases, or when they're archived. Currently both `idea-brainstorming` and `spec-writing` save to `docs/plans/` with no movement or stage tracking.

## Idea

Documents should flow through folders that represent their lifecycle stage:

```
idea-brainstorming          spec-writing              plan-prepare (plan-bd)
     │                           │                       │
     ▼                           ▼                       ▼
docs/idea/<topic>.md  →  docs/spec/<topic>.md  →  docs/archive/<topic>.md
  (freeform)              (structured spec)        (spec + bead IDs)
```

- A document exists in exactly one folder at a time (moved, not copied)
- The folder = the document's current lifecycle stage
- Git tracks the full history of moves
- Filenames use `YYYY-MM-DD-<topic>.md` format

## Phase-Artifact Mapping

| Phase | Skill | Action | Doc format |
|-------|-------|--------|------------|
| idea | `idea-brainstorming` | Creates `docs/idea/YYYY-MM-DD-<topic>.md` | Freeform template |
| spec | `spec-writing` | Moves from `idea/` to `spec/`, restructures content | Structured spec |
| spec | `spec-refinement` | Reviews in-place in `spec/` | Same, refined |
| plan-prepare | `plan-bd` | Inserts bead IDs into doc, moves from `spec/` to `archive/` | Spec + bead IDs |

## Skills That Need Changes

1. **`skills/README.md`** — Add Artifact Lifecycle section documenting the folder flow
2. **`idea-brainstorming/SKILL.md`** — Change output path from `docs/plans/` to `docs/idea/`, define freeform idea template
3. **`spec-writing/SKILL.md`** — Change to move doc from `docs/idea/` to `docs/spec/`, define structured spec format
4. **`plan-bd/SKILL.md`** — After creating bd tasks, insert bead IDs into spec doc, move from `docs/spec/` to `docs/archive/`

## Open Questions

- What sections should the freeform idea template have?
- What sections should the structured spec template have?
- Should `spec-refinement` stage transitions also be documented in the README?
