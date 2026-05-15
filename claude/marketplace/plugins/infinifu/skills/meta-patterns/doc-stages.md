# Document Stage Pipeline

## Four-Stage Folder Convention

All planning/design markdown files move through four folders as they progress through gates.

**Two levels:** shared (cross-cutting) and solution-specific:

```
board/idea/  →  board/spec/  →  board/ready/  →  board/done/           ← shared
solution/<name>/board/idea/ → .../spec/ → .../ready/ → .../done/      ← per solution
```

| Folder | Stage | Created by | Contents |
|--------|-------|------------|----------|
| `board/idea/` | Brainstorming | idea-brainstorming skill | Design exploration, options, decisions |
| `board/spec/` | Specification | spec-writing skill | Implementation plan with tasks, code, tests |
| `board/ready/` | Execution-ready | spec-ready (creates bd tasks + moves file atomically) | Finalized spec with bd epic ID in header |
| `board/done/` | Completed | spec-retro (called by work-merge) | Archived spec after branch merged/PR created |

Use `board/` for cross-cutting work. Use `solution/<name>/board/` for solution-specific work. The stage folders and gate rules are identical at both levels.

## File Naming

```
<topic>.md
```

No date prefix, no `-design` or `-plan` suffix — the folder conveys the stage.

## Gate Rules

### Gate 1: idea → spec
- **Trigger:** User approves the design
- **Action:** `git mv <board>/idea/<file>.md <board>/spec/`
- **Then:** spec-writing skill appends implementation plan to the same file

### Gate 2: spec → ready
- **Trigger:** User approves bd tasks AND spec has bd task IDs written back into each task section
- **Action:**
  1. Write bd task ID into each task section header: `### Task N: Name [bd-xxx]`
  2. Write bd epic ID into the file header: `# Feature Name [epic-xxx]`
  3. `git mv <board>/spec/<file>.md <board>/ready/`
- **Then:** Execution begins (plan-scrum-master or plan-supervised)

### Gate 3: ready → done
- **Trigger:** Branch finishing completes (merge or PR created)
- **Action:** `spec-retro` skill — closes bd epic, then `git mv <board>/ready/<file>.md <board>/done/`
- **Then:** Work is archived. bd epic is closed.

Where `<board>` is either `board/` (shared) or `solution/<name>/board/` (solution-specific).

## Rules

- Files only move forward (idea → spec → ready → done), never backward
- Each gate requires explicit user approval (Gates 1 & 2) or completion (Gate 3)
- The bd epic ID in the header of ready/done files links the doc to its bd tracking
- One file per feature — design and spec content merge into the same file as it progresses
