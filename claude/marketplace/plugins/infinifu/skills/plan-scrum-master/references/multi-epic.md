# Multi-epic parallelism

When multiple epics exist in `board/ready/`, the scrum master can dispatch tasks from different epics in parallel — provided they don't interfere.

## Interference check

Two epics **interfere** if their tasks touch overlapping files or directories. To assess:

1. Read the spec/design for each ready epic.
2. Compare the file paths and domains mentioned.
3. Epics are **non-interfering** if they target completely separate areas of the codebase.

### Examples

| Scenario | Verdict |
|---|---|
| `epic-A` touches `app/auth/` and `epic-B` touches `app/billing/` | non-interfering → parallel OK |
| `epic-A` touches `app/auth/` and `epic-B` touches `app/auth/middleware.ts` | interfering → serialize |
| Either epic touches shared infra (`package.json`, `schema.prisma`, root configs) | interfering → serialize |

## Dispatch rules

- Non-interfering epics: dispatch tasks from all of them, up to `max_parallel` total.
- Interfering epics: serialize — finish one epic's tasks before starting the other.
- If unsure about interference: **ask the human** — do not guess. A wrong call here causes merge conflicts in worktrees that the human will have to untangle.

Present the interference assessment in the dispatch summary for human approval. The dispatch summary template (see main SKILL.md) has a dedicated `Interference:` line — fill it in even when there is only one epic (write `n/a — single epic`).
