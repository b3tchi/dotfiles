# Route Decision: work-do → spec-refinement

**Task:** `wd2-4178385-4pd.1` — Task 1: Add rotate_secret helper to vault.py
**Skill invoked:** `infinifu:work-do`
**Decision:** STOP. Route back to `infinifu:spec-refinement`.
**Status change applied:** none — task left in `OPEN`. Implementer did NOT
mark `in_progress` because the prerequisite gate failed.

## Why I stopped

The `work-do` SKILL.md prerequisites are explicit:

> 2. `bd show <id>` has a design field with enough detail to implement — if
>    it doesn't, STOP and route back for refinement via `spec-refinement`.

For `wd2-4178385-4pd.1`, `bd show` returns:

```
DESIGN
TBD — needs refinement.
```

That is literally a refinement placeholder, not a spec. Implementing against
it would mean inventing the contract — the exact failure mode the gate exists
to prevent.

## The information IS available — it just isn't on the bd task

The epic's spec file `docs/notes/spec/sp001.md` contains a fully-formed Task 1
section (lines 47–80 of sp001.md):

- `files_touched` — `src/lib/vault.py`, `tests/lib/test_vault.py`
- `success_criteria` — 3 concrete criteria including the alias-flip behavior
- `edge_cases` — concurrent rotate, vault unreachable, empty/None value
- `test_plan` — 5 named tests, each tied to a specific bug class

So this is **not** a "spec missing" problem. It is a **"bd task not synced
from spec"** problem. The structured spec block was written but never copied
into the bd task body. `bd show wd2-4178385-4pd.2` and `.3` both have proper
inline design text — only `.1` was left as a TBD stub.

Per the work-do AKM-hooks block, when bd task body is ambiguous the upstream
zettel (`us003` AC + `sp001.tasks` block matching `#### bd wd2-4178385-4pd.1`)
is the ground truth. That zettel content needs to land on the bd task before
`work-do` can run.

## What spec-refinement needs to do

Minimum work for `spec-refinement` to unblock this task:

1. Copy the Task 1 block from `docs/notes/spec/sp001.md` (the section under
   `### Task 1: Add rotate_secret helper to vault.py`) into the bd task
   design field via `bd update wd2-4178385-4pd.1 --design "..."`.
2. Verify the success_criteria and test_plan survive the copy — those are
   what the reviewer (`work-audit`) will check against later.
3. Confirm `us003` acceptance criteria are referenced or inlined so the
   ground-truth contract is visible from the bd task alone.
4. Once the design field is non-stub, re-dispatch via `work-do` for
   `wd2-4178385-4pd.1`.

## What I did NOT do (and why)

| Action | Skipped because |
|---|---|
| `bd update --status in_progress` | Gate failed before claim; claiming an unimplementable task wastes the slot and pollutes review. |
| Edit `src/lib/vault.py` | No contract to implement against. |
| Write `tests/lib/test_vault.py` cases | Test plan exists in sp001 but not on the task; encoding it without re-syncing would let the bd-vs-spec drift compound. |
| File a discovery task | The deviation IS the routing decision; no separate task needed. The drift between sp001 and bd is the artifact `spec-refinement` will fix. |
| `bd close` anything | Closing is a reviewer transition (work-audit). Not implementer's. |
| Mutate any zettel | work-do is read-only on the PKM per AKM hooks. |

## Recommended next action for the dispatcher

Re-route this task to `infinifu:spec-refinement` with this note. After the bd
task design is populated from `sp001.md` Task 1 block, re-dispatch back to
`work-do`.
