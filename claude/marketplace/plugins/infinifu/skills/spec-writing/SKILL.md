---
name: spec-writing
description: Use after idea-brainstorming produces a design, before any code is written — turns loose requirements into a concrete implementation plan document that spec-refinement can then review and plan-bd can turn into tracked tasks. Invoke this whenever a multi-step task needs a written plan before anyone starts coding.
---

# Spec Writing

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the spec-writing skill to create the implementation spec."

**Context:** This should be run in a dedicated worktree (created by idea-brainstorming skill).

**Save plans to:** `board/spec/<feature-name>.md` — this is the same file that was moved from `board/idea/` by the brainstorming skill. Replace its design content with the implementation spec.

## Epic lifecycle — bump to P3

Before writing the spec body, find the epic that `idea-brainstorming` created for this topic and bump its priority to P3 (designing):

```bash
bd list --type epic --priority 4                    # Find the P4 idea epic for this topic
bd update <epic-id> --priority 3                    # Bump to P3 (spec stage)
bd update <epic-id> --design "<updated design with spec doc path: board/spec/<feature-name>.md>"
```

**Why P3:** the idea is now being designed into an implementation spec — a stronger commitment than the raw idea but still pre-task-creation. If no P4 epic exists (e.g., someone skipped brainstorming and went straight to spec), create one now directly at P3: `bd create "Epic: <topic>" --type epic --priority 3 --design "..."`. Keep the epic ID handy — `spec-ready` will bump it to P2 and attach child tasks to it.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Document Skeleton

Write the whole spec from this skeleton end-to-end. The title is H1; every
sibling section — header fields, optional context, and each task — is H2.
Nothing below a task should go deeper than H3 (and most steps use **bold**
step markers, not headings, so the outline stays flat and scannable).

````markdown
# [Feature Name] Implementation Plan

> **For Claude:** Use infinifu:plan-scrum-master (automated) or infinifu:plan-supervised (user reviews each batch) to implement this plan.

**Goal:** [One sentence describing what this builds]

**User stories:** [List ids from `product/stories.yaml` this spec satisfies, e.g. `2605-001`, `2605-003`. Omit field if no user-facing story applies.]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---

## Conventions (optional, include when repo has non-obvious rules)
- [e.g. Services live under `src/services/<name>/`]
- [e.g. Tests mirror source tree under `tests/`]
- [Anything the junior would otherwise have to guess]

## File tree (optional, helpful for specs touching 5+ files)
```
src/services/<name>/
├── __init__.py
├── app.py
├── ...
tests/services/<name>/
├── test_...py
```

## Task 1: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

**Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

**Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

**Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```

## Task 2: [Next Component]
[... same 5-step structure ...]

## Task N: [Last Component]
[... same 5-step structure ...]
````

Tasks run in dependency order — if Task 3 imports from Task 2's module,
Task 2 must come first. Call that out explicitly when the order isn't
obvious from names alone.

## Remember
- Exact file paths always
- Complete code in plan (not "add validation")
- Exact commands with expected output
- Reference relevant skills with @ syntax
- DRY, YAGNI, TDD, frequent commits

## Next Steps

After saving the spec document:

1. **Spec refinement** (mandatory for non-trivial specs):
   - Use infinifu:spec-refinement — SRE 8-category checklist
   - Re-reviews until APPROVED
   - Skippable only for single-task fixes

2. **⛔ MANDATORY GATE — User approves spec:**
   - Present the spec to the user
   - **STOP and wait for explicit user approval**
   - Do NOT create bd tasks until the user approves
   - The user may revise scope, approach, or priorities

3. **Spec ready** (spec-ready creates tasks + promotes to ready):
   - Use infinifu:spec-ready — creates bd epic + tasks with dependencies, moves spec to `board/ready/`
   - This is one atomic operation: tasks created + file promoted in the same commit

4. **⛔ MANDATORY GATE — User approves bd tasks:**
   - Present the bd task list to the user
   - **STOP and wait for explicit user approval**
   - Do NOT start execution until the user approves
   - The user may reorder, edit, add, or remove tasks

5. **Plan-dispatch** (execution):
   - User chooses: plan-scrum-master (automated) or plan-supervised (user reviews batches)

**Self-contained rule:** Each task in the spec must be implementable with ONLY the spec and codebase access. If someone can't do the task without asking questions, the spec is incomplete.
