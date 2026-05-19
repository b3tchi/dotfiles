# work-merge eval-3-wrong-status-spec — run notes

## Invocation

User invoked `work-merge` on sp001 in the Acme sandbox. Task ids supplied
via `.work-do-task-ids.json`:

```json
{
  "epic": "wd3-247277-bsz",
  "task_1": "wd3-247277-bsz.1",
  "task_2": "wd3-247277-bsz.2",
  "task_3": "wd3-247277-bsz.3"
}
```

## Skill behavior

work-merge's Entry-specific checklist step 2 requires `status: ready`.
sp001 frontmatter is `status: spec`. Skill Disambiguation explicitly
covers this case:

> `sp###` at `status: spec` → route to `spec-refinement` (no plan/tasks
> yet).

The skill therefore refused to perform any AKM lifecycle writes and routed
to `infinifu:spec-refinement` (with `infinifu:spec-ready` as the follow-up
after refinement validates the plan). Route decision document written to
`<sandbox>/route_decision.md`.

## What was checked

- `docs/notes/spec/sp001.md` frontmatter: `status: spec` confirmed (line 4).
- `docs/board.md`: sp001 is listed under `## spec` (line 9), NOT under
  `## ready` (which is empty).
- `bd list --json`: epic `wd3-247277-bsz` exists with
  `dependency_count: 0` — the three task ids in `.work-do-task-ids.json`
  have not been materialized as bd children yet. This is fully consistent
  with `status: spec` (pre-promotion).
- Spec body inspection: `## plan`, `## tasks` (3 task stubs with bd ids,
  effort, success_criteria, edge_cases, test_plan) are present. Content is
  refinement-ready; bd materialization + status flip is what's missing.
- Git state at entry: clean working tree on `master`, only untracked file
  was `.seed_manifest.txt` (eval seeding artifact).

## What was NOT done (per Disambiguation block)

- No edit to `sp001.md` frontmatter or footer (`Index: [[board]]` stays).
- No edit to `us003.md` status.
- No edit to `im002.md` status.
- No removal of `[[sp001]]` from `docs/board.md`.
- No addition of `[[sp001]]` to `docs/archive.md`.
- No `bd close wd3-247277-bsz`.
- No bd task creation from `.work-do-task-ids.json` (that's `spec-ready`'s
  job, not work-merge's).
- No test run (tests are gated behind the status precondition).
- No git checkout/merge/push/PR (no landing because there's nothing to
  land).
- No commit. The only thing staged is the untracked `.seed_manifest.txt`
  per the eval capture protocol; AKM files are untouched.

## Captured artifacts

- `outputs/git-status.txt` — single line: `A  .seed_manifest.txt`. No AKM
  files staged.
- `outputs/git-diff.patch` — 61 lines, contents of `.seed_manifest.txt`
  only. Confirms zero AKM writes.
- `outputs/bd-list.json` — single epic, no child tasks.
- `<sandbox>/route_decision.md` — primary route `spec-refinement`,
  follow-up `spec-ready`, with evidence and handoff message.

## Verdict

Skill behavior matches the eval expectation: Disambiguation fired on
`status: spec`, no AKM writes occurred, routing recommendation points to
`spec-refinement` (and `spec-ready` as the follow-up). work-merge declined
to act, as designed.
