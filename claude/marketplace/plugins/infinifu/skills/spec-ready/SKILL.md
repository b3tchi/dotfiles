---
name: spec-ready
description: Use when a spec is written and refined — creates bd epic and tasks with dependencies, then promotes spec from board/spec/ to board/ready/ as one atomic operation
---

# Spec Ready

Gate between spec-writing and development. Takes a finished, refined spec and makes it ready for development: creates bd epic + tasks with dependency analysis, then moves the spec to `board/ready/`.

**Announce at start:** "I'm using the spec-ready skill to plan tasks and promote the spec to ready."

## When to Use

- After infinifu:spec-writing + infinifu:spec-refinement are complete and user has approved the spec
- When a spec exists in `board/spec/` and needs bd tasks created
- Any time you would use `update_plan` for tracking work items from a spec

## Core Principle

**bd is your persistent memory.** Unlike flat plans that vanish between sessions, bd issues survive context resets. Always use bd for tracking work.

## bd Command Reference

For the full command catalogue — reading, creating, updating, inspecting, dependencies — see `infinifu:meta-patterns` (`bd-commands.md`). Load it when you need a specific invocation. Valid statuses: `open`, `in_progress`, `blocked`, `closed`.

This skill calls `bd update` (bump existing epic to P2), `bd create` (tasks, with `--parent` for child links), `bd dep add` (blocking dependencies), `bd list --parent` / `bd ready` (verification), and `git mv` + commit (promote to ready). bd 1.0 auto-exports `.beads/issues.jsonl` after every mutation, so there is no separate `bd sync` step. Patterns specific to those steps appear inline below; everything else lives in the shared reference.

**Epic already exists:** the epic was created at P4 by `idea-brainstorming` and bumped to P3 by `spec-writing`. This skill bumps it to P2 and attaches child tasks — it does NOT create a new epic. If no epic exists (spec came in without going through brainstorming/spec-writing), create one directly at P2 as a fallback.

## Plan-Prepare: Dependency Analysis and Parallelism

When creating tasks from a spec (the plan-prepare phase), analyze the work for:

**1. Dependency chains** — which tasks must complete before others can start?
- Data models before API endpoints
- API endpoints before UI components
- Infrastructure before application code

**2. Parallel workstreams** — which tasks have no dependencies between them?
- Independent components can be dispatched simultaneously
- Use `bd list --parent <epic-id>` (authoritative child list) and `bd ready` / `bd blocked` to verify parallel paths — `bd dep tree <epic-id>` without flags only shows blockers of the epic, not its children

**3. Blockers** — what external dependencies or decisions could stall work?
- Mark with `bd update <id> --status blocked`
- Document what's blocking in the description

**Process:**
```bash
# 1. Find the P3 epic created earlier by idea-brainstorming + spec-writing
bd list --type epic --priority 3          # Locate the epic for this topic

# 2. Bump to P2 (committed — has concrete tasks) and refresh design
bd update <epic-id> --priority 2 --design "<spec summary + path to board/spec/<topic>.md>"

# 3. Create tasks as children of the epic in one step (--parent attaches them)
bd create "Task: ..." --type task --priority 2 --parent <epic-id>

# 4. Set execution order (sequential blocking deps)
bd dep add <task-B> <task-A>    # B depends on A

# 5. Verify the plan
bd list --parent <epic-id>      # list all children of the epic
bd ready                        # unblocked tasks (parallel candidates)
bd blocked                      # what's waiting
# Optionally visualize: bd dep tree <task-id> --direction=both
```

If no P3 epic exists (spec came in without going through the earlier skills), create one inline at P2: `bd create "Epic: <topic>" --type epic --priority 2 --design "..."` and proceed with task creation.

The `bd ready` output after setup should show the root tasks that can start immediately — these are your parallel workstreams for plan-dispatch.

> **Why `bd list --parent` instead of `bd dep tree <epic-id>`?** `bd dep tree` defaults to *downward* (what blocks the given issue). An epic has no blockers, so the tree shows just the epic. `bd list --parent` enumerates the children directly and is the reliable verification command.

## Workflow Integration

Use bd instead of flat plans at these points in the infinifu lifecycle:

### Epic priority tracks the lifecycle stage

Epic priority escalates as commitment grows. Every skill in the chain either creates or bumps the epic:

| Stage | Skill | Epic action | Priority |
|-------|-------|-------------|----------|
| Idea | `idea-brainstorming` | create | P4 |
| Spec | `spec-writing` | bump | P3 |
| Ready | `spec-ready` | bump + attach child tasks | P2 |
| Dispatched | `plan-scrum-master` | bump + `status: in_progress` + bump child tasks | P1 |
| Retro | `spec-retro` | close | — |

**This skill is stage 3: P2.** Do not create a new epic unless no upstream epic exists. Reuse the P3 epic from `spec-writing`. Child tasks are created here for the first time.

### During infinifu:spec-writing
- Epic exists (at P3); this skill created no tasks. `spec-ready` takes over task creation.

### During infinifu:plan-supervised
- Use `bd ready` to find the next task (replaces manually scanning a checklist)
- Mark `in_progress` when starting, `close` when done
- Create new issues for discovered work: `bd create "Discovered: ..." --type task`
- Link discoveries: `bd dep add <new> <parent> --type discovered-from`

### During infinifu:plan-scrum-master
- Scrum master reads `bd ready` to find available tasks
- Dispatches implementer agents who claim tasks with `bd update --status in_progress`
- Dispatches reviewer agents who verify and close tasks with `bd close`
- Scrum master itself only reads bd — agents perform state transitions

### Resuming Work (Any New Session)
1. Run `bd ready` to orient yourself
2. Check `bd list --status in_progress` for anything left mid-flight
3. Pick up where you left off -- no context needed, bd has it all

## Process: Spec → Ready

1. **Bump existing epic to P2 (committed):**
```bash
# Find the P3 epic from spec-writing (or P4 if spec-writing was skipped)
bd list --type epic --priority 3

bd update <epic-id> --priority 2 \
  --design "## Goal
[What we're building]

## Success Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Approach
[High-level strategy]

## Spec
See board/spec/<topic>.md"
```

If there is no existing epic (rare — only when spec arrived without going through brainstorming/spec-writing), create one directly at P2: `bd create "Epic: <topic>" --type epic --priority 2 --design "..."`.

2. **Create tasks with `--parent` linking them to the epic, then add blocking deps for execution order:**
```bash
# First task (no blockers) — child of the epic
bd create "Set up project structure" --type task --priority 2 --parent <epic-id> \
  --design "Create directories, config files, initial scaffolding"
# Capture ID as <task-1-id>

# Second task depends on first
bd create "Implement core logic" --type task --priority 2 --parent <epic-id> \
  --design "Build the main feature following TDD"
# Capture ID as <task-2-id>
bd dep add <task-2-id> <task-1-id>

# Third task depends on second
bd create "Add API endpoints" --type task --priority 2 --parent <epic-id> \
  --design "REST endpoints exposing core logic"
# Capture ID as <task-3-id>
bd dep add <task-3-id> <task-2-id>
```

> **Why `--parent` instead of a separate `bd dep add ... --type parent-child`?** In bd 1.0 `bd create` accepts `--parent <epic-id>` and wires the parent-child link atomically. Halves the commands and removes the chance of forgetting the link. Use `bd dep add` only for blocking (execution-order) dependencies.

3. **Verify the plan:**
```bash
bd list --parent <epic-id>   # Every task under this epic (the authoritative child list)
bd ready                     # Should show only the first unblocked task
bd blocked                   # Optional: everything waiting, with what's blocking it
```

4. **Promote spec to ready** — this is the atomic closing step of spec-ready. Every spec lives in `board/spec/` until bd tasks exist; once they do, move it to `board/ready/` so it is visibly ready for development:
```bash
# Write epic ID into spec header and task IDs into each task section header, then:
git add .beads/                                                    # bd 1.0 auto-exports .beads/issues.jsonl after every mutation; just stage it.
git mv board/spec/<topic>.md board/ready/<topic>.md
git commit -m "chore: promote <topic> to ready [<epic-id>]"
```
**This step is not optional.** `board/ready/` = spec has bd tasks and is ready for a developer to pick up. `board/spec/` = spec written but not yet planned. Never leave a spec in `spec/` after creating bd tasks.

## ⛔ MANDATORY GATE — User Approves Tasks Before Execution

After creating all bd tasks and setting dependencies, you MUST:

1. Present the full task list to the user (use `bd ready`, `bd list --parent <epic-id>`, `bd stats`)
2. **STOP and wait for explicit user approval**
3. Do NOT start any execution until the user says to proceed
4. The user may reorder, edit, add, or remove tasks before approving

**This gate is not optional.** Creating bd tasks does not authorize execution.

## Process: Executing Tasks

1. **Find ready work:**
```bash
bd ready
```

2. **Start the task:**
```bash
bd show <task-id>                     # Read full details
bd update <task-id> --status in_progress
```

3. **Do the work** (follow infinifu:domain-tdd):
   - Write failing test
   - Implement minimal code
   - Verify tests pass
   - Commit

4. **Close and move on:**
```bash
bd close <task-id> --reason "Implemented: [brief summary]"
bd ready                              # Next task is now unblocked
```

5. **Handle discoveries:**
```bash
# Found something unexpected during work
bd create "Discovered: [issue]" --type task --priority 1 --parent <epic-id> \
  --design "Found while working on <task-id>: [details]"
bd dep add <new-id> <task-id> --type discovered-from
```

## Common Mistakes to Avoid

- **Using `update_plan` for multi-step work** -- Use bd instead. Flat checklists don't survive context resets.
- **Forgetting to check bd at session start** -- Always run `bd ready` first.
- **Closing tasks without verification** -- Run tests before closing. Use infinifu:domain-verification.
- **Creating tasks without dependencies** -- Every task should link to its epic and blockers.
- **Using `--status done`** -- Not valid. Use `bd close` to complete tasks.
- **Using hyphens in status** -- Use underscores: `in_progress` not `in-progress`.
- **Leaving spec in `board/spec/` after creating tasks** -- Once bd tasks exist, `git mv board/spec/<topic>.md board/ready/<topic>.md` is mandatory. `ready/` means planned and ready for development.
