---
name: work-audit
description: Use when auditing a single bd task after the implementer reported ready (task still `in_progress` with implementation notes) — compare the design and success criteria against what was actually shipped, verify tests catch real bugs, and catch dead code left from refactoring. This is the per-task verification gate invoked by reviewer agents (and by solo devs after `work-do`). You own the `in_progress → closed` transition: approved → you call `bd close` with audit evidence; rejected → add gap notes and leave `in_progress` for the implementer to retry. Epic-level completeness is just every task passing its own audit.
---

<skill_overview>
Audit one bd task: did the implementation fulfil the task's contract without deviation, and is every success criterion met with evidence? The task is the contract. Every claim you make (approved or rejected) is backed by a file:line citation, a command output, or a search result — not vibes.
</skill_overview>

<rigidity_level>
LOW FREEDOM — the checks are rigid because the task's value as a contract collapses if audits get skipped or hand-waved. What adapts: the specific tools (test runner, linter, language) and the format of the rejection report. What doesn't: running the automated checks, reading the changed files (not just the diff), and verifying every criterion against real output.
</rigidity_level>

<evidence_requirements>
## Evidence-based review

Every finding needs evidence. Rate each at 0.0–1.0:

- **1.0** — Verified directly (ran command, read code)
- **0.8** — Strong indirect evidence (multiple consistent signals)
- **0.5** — Uncertain (partial evidence, assumptions made)
- **0.3** — Weak (limited investigation)

Findings below 0.8 must be investigated until ≥0.8 or marked UNCERTAIN in the rejection. A 0.5 "maybe this is a gap" is not a reject — investigate first.

**Required evidence by claim type:**

| Claim | Evidence |
|-------|----------|
| "Code implements X" | File path:line number showing the implementation |
| "Test covers Y" | Test name + specific assertion |
| "Criterion met" | Command output proving the criterion |
| "No anti-pattern" | Search command showing no matches |
| "Deviated from design" | Quote from task design + what was built instead |
</evidence_requirements>

<quick_reference>
| Step | Action | Deliverable |
|------|--------|-------------|
| 1 | Load the task: `bd show <id>` | Design, criteria, checklist, anti-patterns |
| 2 | Read the actual changed files (not just diff) | Full-file context |
| 3 | Run automated checks (TODOs, stubs, dead code, quality gates) | Hit list |
| 4 | Verify every success criterion with evidence | Criteria table |
| 5 | Audit new tests for meaningfulness | Test-quality notes |
| 6 | Compare design direction vs. what was built | Deviation check |
| 7 | Decide: approved or reject with evidence | Verdict |

**Review perspective:** senior SRE with 20+ years reviewing junior engineer code.

**Test quality gate:** every new test must catch a real bug. Tautological tests (pass by definition, test mocks, verify compiler-checked facts) are gaps, not coverage.
</quick_reference>

<when_to_use>
**Use when:**
- You are a reviewer agent dispatched by `plan-scrum-master` after an implementer reported a task ready (left `in_progress` with evidence notes)
- You are a solo developer who just finished `work-do` on a task and want to verify before moving on
- Anyone is about to accept a task as "done" and needs to check it

**Don't use for:**
- Epic-wide sign-off — just run this per task; epic completeness is the aggregate
- Mid-implementation checks — use `infinifu:domain-verification` for spot checks during work
- External PR reviews — this is audit against a bd task contract, not code review dialogue (for that, use `infinifu:domain-review-requesting` / `domain-review-receiving`)
- Work with no bd task — refine into tasks first with `infinifu:spec-refinement`
</when_to_use>

<the_process>

**Announce:** "I'm using infinifu:work-audit to verify task `<id>` against its design."

## AKM hooks

Stage 6 of the AKM lifecycle — see `claude/akm/akm-lifecycle.md` for the full map and `claude/akm/akm.md` for typed-zettel schemas. Read-only on the PKM.

**Reads:**

- `us###.acceptance_criteria` — the binding contract. Audit against this, not just the bd task body. A task can be technically "done" against the bd description but still fail the story AC; that is a rejection.
- `sp###.tasks` block matching `#### bd <task-id>` — `#### success_criteria`, `#### edge_cases`, and `#### test_plan` are the assertions the implementation must satisfy.

**Writes:** none. Audit evidence belongs in the bd task notes; `bd close` (approval) or gap notes (rejection) is the only state transition this skill owns.

## Step 1 — Load the task

```bash
bd show <id>
```

Extract: goal, design, success criteria, implementation checklist, key considerations, anti-patterns list. These are the contract — every audit decision maps back to one of them.

Also check what the implementer recorded:

```bash
bd show <id>   # includes notes/deviations logged during work-do
```

If the implementer logged a DEVIATION note, that's not automatically a rejection — they surfaced it honestly. Verify the deviation is still acceptable (design still fulfilled in spirit) or reject if the deviation invalidates the criterion.

**Never read `.beads/issues.jsonl` directly.** Use `bd` commands — they return canonical state.

### Pre-flight gate: the branch MUST have commits

Before reading a single line of code, verify the implementer actually committed:

```bash
git -C "$WT" log --oneline "$BASE".."$BRANCH"    # BASE is usually main
```

**Empty output → REJECT immediately.** Do not read the worktree, do not audit, and above all **do not commit the work yourself**.

This is not pedantry. `work-merge` merges the *branch*; an uncommitted worktree means a branch with zero commits, a silent no-op merge, and work that survives only because `git worktree remove` refuses to delete dirty state. The tempting move — "the diff is right there in the worktree, I'll just commit it and land it" — **collapses the review gate**: you become the author of the artifact you just approved, and nothing independently verifies that what got committed is what got reviewed. That exact sequence happened once and is why this gate exists.

Bounce it back instead:

```bash
bd update <id> --notes "REJECTED (pre-flight): branch <branch> has no commits over <base>. work-do Step 7 requires committing before reporting ready. Worktree left intact; commit and re-report."
```

Then report the rejection to the dispatcher. The implementer still has its worktree and full context; committing is a ten-second fix for them and a gate violation for you.

## Step 2 — Read the actual changed files

```bash
git diff main...HEAD   # scope of what changed in this task
```

(If this is empty but the worktree has changes, you skipped the pre-flight gate above — go back.)

Then open each changed file with the Read tool. Reading the full file — not just the diff — is the single most important discipline. The diff hides missing code: if validation *should* have been added and wasn't, the diff has nothing to show you. Only the full file reveals the gap.

While reading, check:

- Implementation fulfils every checklist item (not stubs)
- Error handling uses proper patterns (Result, try/catch, error propagation)
- Edge cases from "Key Considerations" are handled in code, not just mentioned in comments
- Code reads clearly — a junior engineer should understand it in six months
- No anti-patterns present

## Step 3 — Run automated checks

Load `references/audit-commands.md` for the full catalogue. It covers:

- TODOs/FIXMEs, stubs, unsafe patterns, ignored tests
- Dead code: fallback naming, feature flags for old code, `was:`/`previously:` comments, language-specific unused-code detectors, orphaned tests, deprecation markers, backwards-compat shims
- Anti-pattern search for every prohibited pattern the task listed
- Quality gates via `test-runner` agent (tests, format, lint, pre-commit)

Every hit is a finding. Dead code left from a refactor is not a nit — the refactor is incomplete.

## Step 4 — Verify success criteria with evidence

For each criterion in the task, run a verification command and paste the real output. Don't assume — verify.

```
Criterion: "All tests passing"
Command:   cargo test
Evidence:  "127 tests passed, 0 failures"
Result:    ✅ Met
```

If a criterion can't be verified with a concrete command, the criterion was badly written — flag it, don't let the task pass on interpretation.

## Step 5 — Audit new tests

Every new or modified test must answer: *what bug would this catch?* If you can't name one, the test is tautological — false confidence is worse than no test.

Four questions per test:

1. What bug would this catch? (If you can't name one → RED)
2. Could production code break while the test still passes? (Yes → weak)
3. Does it exercise a real user scenario?
4. Is the assertion meaningful? (`result == expected` beats `result != nil`)

**Red flags:** tests that only verify syntax/existence, tautological tests (`expect(builder.build() != nil)` when `build()` can't return nil), tests duplicating implementation, tests without meaningful assertions, tests that verify mock behaviour, generic names (`test_basic`, `test_it_works`).

For a deep test-quality audit (mutation testing, coverage gaming, full RED/YELLOW/GREEN taxonomy across the whole suite), escalate to `infinifu:domain-test-effectiveness` — that's a separate, heavier review for a test suite, not a per-task check.

## Step 6 — Compare design direction vs. what was built

This is the heart of the audit. Re-read the task design and ask: did the implementation take the direction the design laid out, or did it quietly pivot?

Common deviation shapes:

- Different approach than described (e.g., design said "extract validator class", implementation inlined a helper function instead)
- Scope narrowed silently (e.g., design listed 3 validators, implementation added 2 and left the third as a stub)
- Scope expanded silently ("while I was here…" — should have been a new bd task)
- Key consideration skipped (design flagged concurrency; code has a race)

If the implementer logged a DEVIATION note in bd, they flagged it honestly — decide whether the deviation is acceptable (often it is — specs are imperfect). If they didn't log it but it exists, that's a harder reject because the honest-deviation discipline was violated.

## Step 7 — Verdict (you own the state transition)

The implementer left the task `in_progress` with evidence notes. You, the reviewer, own the `in_progress → closed` transition. That gate is what makes `closed` mean "reviewed and approved" rather than "implementer thinks it's done".

### Approved

Every success criterion has evidence, no automated-check hits, no anti-patterns, no silent deviation, tests meaningful.

Close the task with audit evidence:

```bash
bd close <id> --reason "AUDITED: APPROVED

Criteria verified:
- <criterion 1>: <evidence>
- <criterion 2>: <evidence>
Tests: <N passed, N new>
Deviations: <either 'none' or 'logged and acceptable: <note>'>"
```

**Then auto-trigger `infinifu:work-merge` with the task id, the approved iteration `<N>`, AND the post-merge `<test-command>`.** The iteration comes from the audited worktree's branch name `bd-<id>.<N>` (`git -C <worktree> branch --show-current`, then split on `.`).

**Derive `<test-command>` from the task's own `success_criteria` — do not invent one.** Use exactly what the criteria claim will pass (e.g. a criterion reading "`npm run test:unit` green" ⇒ gate is `npm run test:unit`). Do **not** substitute a broader repo-wide "quality" command the task never claimed: if it is already red on base for unrelated reasons, the gate can never pass and you will roll back a good merge and report a false `POST-MERGE FAIL`. You have just measured these commands yourself during the audit — pass the one you watched go green. If a criterion is shaped "no NEW errors vs baseline" rather than "zero errors", that is not expressible as an exit code: keep it out of the gate (you already verified it with real numbers) and gate on the clean binary part. See work-merge's "Choosing `<test-command>`" for the full rule.

work-merge is the per-task land step — it merges `bd-<id>.<N>` into base locally, runs the post-merge test gate, removes the worktree, sweeps any sibling rejected iterations of the same task, and (if this was the last open child of the parent epic) flips the AKM lifecycle + archives the spec + closes the bd epic. All operations are local; no push. This trigger is part of the audit-approve gesture — the dispatcher / user should not be required to type a separate "merge" command.

work-merge's possible outcomes:

| Result | Meaning | Next |
|--------|---------|------|
| `TASK_LANDED` | Merge clean, tests green, worktree removed. Other tasks still open in the epic. | Report APPROVED to dispatcher; pipeline continues. |
| `TASK_LANDED + EPIC_DONE` | Same as above plus the epic finale fired (AKM flip + board→archive + bd close epic). | Report APPROVED + EPIC_DONE; dispatcher runs `spec-retro` to refresh the graph and push. |
| `POST-MERGE FAIL` (exit 2 from `land-bd-task.sh`) | Tests failed after merging into base; merge rolled back; task reopened with a `POST-MERGE FAIL` note. | **First: was the gate legitimate?** Re-run `<test-command>` on base WITHOUT the merge. If it fails there too, the gate was impossible and this is a gate bug, not a code defect — fix the command (see "Choosing `<test-command>`"), re-run the land, and do NOT reject the implementer for it. Only if the command is green on base and red after the merge is this a real integration failure: convert to a REJECTED verdict and re-dispatch the implementer with the post-merge failure as the gap. |

Then report to the dispatcher:

```
Task <id>: APPROVED (closed + landed locally)

Criteria:
- <criterion 1>: <evidence>
- <criterion 2>: <evidence>
Tests: <N passed, N new>
Deviations: <either 'none' or 'logged and acceptable: <note>'>
Land result: <TASK_LANDED | TASK_LANDED + EPIC_DONE>
Epic <epic-id>: <N open children remaining | closed — run spec-retro for sp###>
```

### Rejected

One or more gaps found. Leave the task `in_progress` (do NOT close — the work isn't done) and record the rejection on the task itself so the next implementer dispatch has the evidence:

```bash
bd update <id> --notes "AUDITED: REJECTED

Gaps:
- <criterion or check>: <what's missing, with file:line or command output>
- <next gap>: ...

Requested action: <what the implementer needs to do to pass re-audit>"
```

Then report to the dispatcher:

```
Task <id>: REJECTED (left in_progress, notes updated)

Gaps:
- <criterion or check>: <what's missing, with file:line or command output>
- <next gap>: ...

Requested action: <what the implementer needs to do to pass re-audit>
```

The dispatcher re-dispatches the implementer, who reads the updated notes with the rejection evidence and fixes the gaps. Re-run the audit after they report ready again. If rejected twice on the same gap, escalate to the human — don't loop indefinitely.

</the_process>

<critical_rules>
1. **Audit one task per invocation.** Don't batch — each task has its own contract.
2. **Run all automated checks.** TODOs, stubs, unwrap, ignored tests, dead code.
3. **Read actual files with the Read tool.** Not just `git diff`.
4. **Verify every success criterion with command evidence.** Not assumptions.
5. **Check every anti-pattern explicitly.** Search for prohibited patterns.
6. **Apply senior-SRE scrutiny.** Production-grade review, not surface-level.
7. **Audit every new test for meaningfulness.** Tautological tests are gaps.
8. **Reject on silent deviation.** Unlogged design departure is a discipline failure.
9. **If gaps found, reject with evidence.** No vague "looks incomplete".

## Common excuses

These thoughts all mean the audit is skipping work it shouldn't:

- *"The branch has no commits but the diff is right there — I'll just commit it and land it"* — **no.** Committing the work makes you the author of what you're approving; nothing then verifies that the committed tree matches the reviewed tree. Pre-flight gate: empty `log base..branch` = reject, bounce to the implementer.
- *"Tests pass, must be complete"* — tests ≠ task criteria; verify every criterion
- *"Implementer says it's done"* — implementer bias is why audits exist
- *"Small task, quick scan is enough"* — small tasks pass small audits, but still get audited
- *"Looks good to me"* — opinion ≠ evidence; run verifications
- *"Can check diff instead of files"* — diff shows changes, not what's missing
- *"Coverage looks good"* — coverage is gameable with tautological tests
- *"Keeping old code as fallback is safe"* — version control remembers; delete now
- *"Backwards compatibility requires the shim"* — internal code doesn't need compat
- *"Deprecation marker is enough"* — deprecation = "delete soon", not "keep forever"
</critical_rules>

<verification_checklist>
Before issuing a verdict:

- [ ] Loaded the task with `bd show <id>`
- [ ] **Pre-flight: `git log base..branch` is non-empty** — the implementer committed; you did not commit on their behalf
- [ ] Ran automated checks (TODOs, stubs, unwrap, ignored tests, dead code)
- [ ] Read changed files with the Read tool, not just the diff
- [ ] Verified every success criterion with a command and real output
- [ ] Audited every new test against the four questions
- [ ] Checked every anti-pattern the task listed
- [ ] Confirmed key considerations are addressed in code, not just comments
- [ ] Compared design direction against what was built (deviation check)

**If approved:** every criterion has evidence above. **If rejected:** each gap has evidence.

Can't check all boxes? Keep auditing — don't issue a verdict on partial work.
</verification_checklist>

<integration>
**Called by:**
- `agents/code-reviewer` — the reviewer agent dispatched by `plan-scrum-master` invokes this skill per task
- `infinifu:work-do` — implementers running solo can invoke this as a self-check before reporting back
- `infinifu:plan-supervised` — user-supervised flow can invoke this between batches

**Calls:**
- `test-runner` agent (for quality gates)
- `infinifu:domain-test-effectiveness` (only when a test-quality issue is systemic — e.g., whole suite has tautology problem — not for every per-task audit)
- `infinifu:work-merge` (auto-triggered on APPROVED verdict — per-task local land + epic finale if last child)

**Uses principles from:**
- `infinifu:domain-verification` — evidence before claims

**Call chain (per task):**

```
implementer (work-do) → records evidence in notes, leaves in_progress
                           ↓
         reviewer agent (work-audit)
          ├── approved → reviewer calls bd close with audit evidence
          └── rejected → reviewer updates notes with gaps, leaves in_progress;
                         dispatcher sends implementer back to fix
```

**State ownership:** the implementer owns `open → in_progress` (claim) and `in_progress → blocked` (stuck). The reviewer owns `in_progress → closed` (approval gate). That split is what makes `closed` mean "reviewed and approved" instead of "implementer thinks it's done".

**Epic completeness** is detected by `work-merge` (auto-invoked on the approved path) — when the just-closed task is the last open child of its parent epic, work-merge runs the epic finale (AKM flip + board→archive + bd close epic). This skill doesn't track it; it just hands the task id to work-merge and reports whatever work-merge returns.

Use `bd` commands (`bd show`, `bd list`, `bd dep tree`), never read `.beads/issues.jsonl` directly.
</integration>

<references>
- `references/audit-commands.md` — all `rg`/build-tool patterns for code completeness, dead code, anti-patterns, and quality gates
- `references/findings-template.md` — per-task findings table and approved/rejected report templates
- `references/examples.md` — five worked examples showing common review shortcuts and the rigorous pass that catches them
</references>
