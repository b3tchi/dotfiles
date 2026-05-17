# Route Decision — work-merge on sp001

## Outcome: BLOCKED

work-merge cannot proceed. The skill's Disambiguation rule fires:

> "bd children not all closed → block; report which tasks are still `open` / `in_progress` / `blocked`. Route to `work-do` (for blocked or open) or `work-audit` (for in_progress with implementer evidence)."

## bd state for epic `wd1-243541-qia` (sp001)

| Task | Title                                          | Status        |
|------|------------------------------------------------|---------------|
| .1   | Add rotate_secret helper to vault.py           | closed (AUDITED: APPROVED) |
| .2   | Add vault_rotate orchestration module          | **in_progress** |
| .3   | Synthetic-check hook for rotation window       | closed (AUDITED: APPROVED) |
| epic | (parent)                                       | open          |

## Blocker

`wd1-243541-qia.2` is still `in_progress`. It has no implementation `notes` field on the bd record yet — the implementer either has not reported `ready`, or `work-audit` has not run on it. Without an audit-approved close on every child, the lifecycle precondition for work-merge is not met.

## What was NOT done (correctly)

No AKM writes were performed. Specifically:

- `docs/notes/spec/sp001.md` — `status: ready` unchanged; footer `Index: [[board]]` unchanged.
- `docs/notes/us003.md` — `status` unchanged.
- `docs/notes/im002.md` — `status` unchanged.
- `docs/board.md` — `[[sp001|...]]` line still under `## ready`.
- `docs/archive.md` — not modified.
- bd epic `wd1-243541-qia` — not closed.
- Tests were not run; no git landing options were presented.

This matches the skill principle: "AKM writes BEFORE git landing … No partial state."

## Routing

1. **Primary:** route `wd1-243541-qia.2` to `work-audit` (if the implementer has reported `ready` with evidence in task notes — currently the bd record shows no `notes` field, so this is likely premature).
2. **Fallback:** if no implementer report exists, route to `work-do` to actually finish the task.
3. Re-run `work-merge sp001` only after every child task on epic `wd1-243541-qia` is `closed`.
