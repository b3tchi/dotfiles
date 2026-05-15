# Infinifu Skills

## Two-Layer Model

Work happens on two layers in parallel. **Layer 1** tracks the epic as a single markdown file moving through `board/` subdirectories. **Layer 2** is the bd task graph that executes the epic's implementation. `spec-ready` is the bridge that creates Layer 2 from Layer 1; `spec-retro` closes Layer 2 and archives Layer 1.

```
Layer 1 — Epic document (one .md file per epic, moves through board/)

  idea-brainstorming   spec-writing      spec-refinement   spec-ready                              spec-retro
  ─────────────────▶   ────────────▶     ──────────────▶   ──────────▶         ...                 ──────────▶
  board/idea/X.md      board/spec/X.md   board/spec/X.md   board/ready/X.md                        board/done/X.md
                                         ⛔ human gate     ⛔ human gate                                   ▲
                                                                │                                         │
                                                                │ creates bd epic + tasks                 │ Layer 2 complete:
                                                                ▼                                         │ close bd epic,
                                                                                                          │ archive .md
Layer 2 — Task graph (bd issues, orchestrated by plan-scrum-master)                                       │

  bd epic                                                                                                 │
     │                                                                                                    │
     ▼                                                                                                    │
  plan-scrum-master  ◀── reads bd ready, dispatches agents (respects max_parallel)                        │
     │                                                                                                    │
     │  per task:                                                                                         │
     │                                                                                                    │
     ├──▶ implementer agent ──▶ work-do ──▶ domain-tdd ──▶ bd close                                       │
     │                                                         │                                          │
     │                                                         ▼                                          │
     ├──▶ reviewer agent (code-reviewer) ──▶ work-audit                                                   │
     │                                            │                                                       │
     │                                            ├── approved → task stays closed                        │
     │                                            └── rejected → re-open, back to implementer             │
     │                                                                                                    │
     └──▶ ... (until bd ready is empty AND every closed task is audited)                                  │
           │                                                                                              │
           ▼                                                                                              │
       work-merge ────────────────────────────────────────────────────────────────────────────────────────┘
```

**Per-task protocol** — every implementer agent (whether spawned by scrum-master, stepped through plan-supervised, or picked up manually from `bd ready`) follows `work-do`: read task with `bd show`, claim it, do the work via `domain-tdd`, log deviations immediately, close with evidence, report back.

**Per-task audit** — after an implementer closes a task, a reviewer agent runs `work-audit`: compares design vs. what was built, verifies every success criterion with evidence, flags silent deviations. Approved tasks stay closed; rejected ones re-open and bounce back with specific evidence of what's missing. Epic completeness is just the aggregate — every task passing its own audit.

**Crossing back to Layer 1** — when `work-merge` lands the branch, control returns to Layer 1: `spec-retro` closes the bd epic and `git mv`s the spec from `board/ready/` to `board/done/`. Layer 2 is about bd tasks; archiving the `.md` is a Layer 1 concern.

**Layer 2 dispatcher options** — pick one based on how much supervision you want:
- `plan-scrum-master` — fully automated: agents implement, reviewer agent verifies, user sees results at the end
- `plan-supervised` — agent implements in batches; user reviews each batch before the next (human-in-the-loop)

## Skill Kinds — Process vs. Domain vs. Meta

The prefix tells you *when* a skill fires:

**Process skills** (flow-ordered — fire at a specific lifecycle step):
- Layer 1: `idea-brainstorming`, `idea-refactoring`, `spec-writing`, `spec-refinement`, `spec-ready`, `spec-retro`
- Layer 2 orchestration: `plan-scrum-master`, `plan-supervised`
- Layer 2 per-task → epic → branch: `work-do` → `work-audit` → `work-merge`

**Domain skills** (toolbelt — pulled in on demand, not tied to a flow position):
- TDD, verification, debugging, bug-fixing, refactor-safely
- Test: `domain-test-anti-patterns`, `domain-test-effectiveness`
- Review: `domain-review-requesting`, `domain-review-receiving` (external code review)
- Infra: `domain-git-worktrees`

**Meta skills** (ambient / infrastructure for the skill system itself):
- `meta-bootstrap` (injected at session start, routes to other skills)
- `meta-skill-writing` (house style for authoring skills)
- `meta-patterns` (shared reference: bd commands, writing patterns)

**Why the split:** process skills have a *when* — scrum-master wouldn't fire during brainstorming. Domain skills have a *why* — you reach for `domain-debug` when something's broken, regardless of stage. Different decision criteria, different prefixes.

## Lifecycle Taxonomy

```
idea → spec → plan → work → done
```

| Stage | Purpose                          | Universal? |
|-------|----------------------------------|------------|
| idea  | Explore what and why             | feature only |
| spec  | Define precisely what to build   | varies by scenario |
| spec-ready | Promote spec to ready: bd tasks, deps, parallelism, git mv to board/ready/ | always |
| work  | Build, test, review, debug       | always |
| done  | Close tasks, cleanup, archive    | always |

## Work Subdomains

Work contains parallel subdomains that interleave during execution:

| Subdomain | What                     |
|-----------|--------------------------|
| code      | Write/change code        |
| test      | Write tests, run tests   |
| review    | Code review              |
| debug     | Find and fix bugs        |
| refactor  | Restructure code         |
| git       | Branches, worktrees      |

TDD cycle (within work):

```
test-write (red) → code (green) → test-run → repeat until green
```

## Scenarios

Scenarios vary in their **entry point** and which **work subdomains** activate.
**spec-ready** (bd task creation + promote to ready) and **done** (close, cleanup, archive) are universal — every scenario includes them.

| Scenario | Entry | Spec | Work subdomains | 
|----------|-------|------|-----------------|
| feature  | idea  | requirements | code, test, review |
| refactor | idea-refactoring | spec-writing | refactor-safely, test |
| fix      | debug | root cause | test-reproduce, code-fix, test-verify |

### Feature

```
idea → spec → plan → work → done
                     ├── test-write (red)
                     ├── code (green)
                     ├── test-run
                     └── review
```

### Refactor

```
idea-refactoring → spec-writing → spec-refinement → plan → work → done
                                                           ├── domain-refactor-safely
                                                           └── test (existing tests as safety net)
```

### Fix

```
debug → spec (root cause) → plan → work → done
                                   ├── test-write (reproduce)
                                   ├── code (fix)
                                   └── test-run (verify)
```

## Stage Transitions

Each transition has: a **trigger** (what causes it), an **artifact** (what gets passed), and a **gate** (what must be true).

**Universal stages**: `plan` and `done` appear in every scenario. Entry points and work subdomains vary by scenario (see above).

### idea → spec

| | |
|-|-|
| **Trigger** | `idea-brainstorming` invokes `Skill(spec-writing)` |
| **Artifact** | Design doc (`board/idea/<topic>.md`) + bd epic |
| **Gate** | User approves design |

### spec-writing → spec-refinement

| | |
|-|-|
| **Trigger** | `spec-writing` produces implementation spec |
| **Artifact** | Implementation spec (`board/spec/<topic>.md`) |
| **Gate** | Mandatory for non-trivial specs (multiple tasks, >4h estimated). Skippable for single-task fixes. |

`spec-refinement` applies an 8-category SRE checklist: granularity, implementability, success criteria, dependencies, safety, edge cases, red flags, test meaningfulness. Re-reviews until APPROVED.

### spec-refinement → spec-ready ⛔ MANDATORY HUMAN GATE

| | |
|-|-|
| **Trigger** | `spec-refinement` approves the spec |
| **Artifact** | Reviewed spec ready for task breakdown |
| **Gate** | **User reviews and approves the spec.** Spec refinement passing is necessary but not sufficient — the user must explicitly approve before bd tasks are created. |

**STOP:** Present the approved spec to the user and wait for explicit approval. Do NOT create bd tasks until the user says to. The user may want to revise scope, approach, or priorities.

`spec-ready` creates the bd epic, breaks tasks into dependency chains, identifies which tasks can run in parallel, sets blockers, and promotes the spec from `board/spec/` to `board/ready/` — all as one atomic operation.

### spec-ready → plan-dispatch ⛔ MANDATORY HUMAN GATE

| | |
|-|-|
| **Trigger** | `spec-ready` has populated the ready queue with tasks, deps, and parallelism, and moved the file to `board/ready/` |
| **Artifact** | bd epic with tasks, dependencies, and blockers; spec file in `board/ready/` |
| **Gate** | **User reviews and approves the bd tasks.** Then user chooses execution strategy: `plan-scrum-master` (automated) or `plan-supervised` (human-in-the-loop batches). |

**STOP:** After creating bd tasks, present the task list to the user and wait for explicit approval. Do NOT proceed to execution until the user says to. The user may want to reorder, edit, add, or remove tasks.

### plan-dispatch → work

| | |
|-|-|
| **Trigger** | `plan-*` dispatches agents to bd ready queue |
| **Artifact** | bd task (`bd show <id>` has full context) |
| **Gate** | `bd ready` returns unblocked task AND user has approved the plan |

Each agent claims a task (`bd update --status in_progress`), does the work, closes it (`bd close`).

### work → work (TDD cycle)

| | |
|-|-|
| **Trigger** | Within a task, `domain-tdd` drives the red-green loop |
| **Artifact** | Code + tests in working tree |
| **Gate** | Tests pass (green) |

```
test-write (red) → code (green) → test-run → repeat until green
```

### work → done

| | |
|-|-|
| **Trigger** | All bd tasks closed, `domain-verification` passes |
| **Artifact** | Working, verified code |
| **Gate** | Verification commands confirm output |

`work-merge` decides: merge, PR, or cleanup. On merge/PR, calls `spec-retro` which closes the bd epic and archives the spec from `board/ready/` to `board/done/`.

## Skill Naming

Skills are prefixed by their lifecycle stage:

| Stage    | Prefix   |
|----------|----------|
| idea     | `idea-`  |
| spec     | `spec-`  |
| plan     | `plan-`  |
| work     | `work-`  |
| done     | `done-`  | *(none yet — covered by `domain-verification` + `work-merge`)* |
| meta     | `meta-`  |

Work subdomains use nested prefixes: `domain-debug-`, `work-refactor-`, `work-test-`, `work-review-`, `work-git-`.

## What Skill Do I Use?

| I want to...                          | Skill                        |
|---------------------------------------|------------------------------|
| Start a new feature                   | `idea-brainstorming`         |
| Write an implementation spec          | `spec-writing`               |
| Review spec quality before execution  | `spec-refinement`            |
| Create bd tasks + promote spec to ready | `spec-ready`               |
| Execute a plan with automated review  | `plan-scrum-master`          |
| Execute a plan with human-in-the-loop batches | `plan-supervised`    |
| Implement a single bd task (per-task protocol) | `work-do`  |
| Write code TDD style                  | `domain-tdd`                   |
| Fix a bug                             | `domain-bug-fixing`            |
| Debug a bug or test failure           | `domain-debug`                 |
| Start a refactoring                   | `idea-refactoring`           |
| Refactor safely                       | `domain-refactor-safely`       |
| Avoid test anti-patterns              | `domain-test-anti-patterns`    |
| Audit test quality                    | `domain-test-effectiveness`    |
| Verify before claiming done           | `domain-verification`     |
| Request a code review                 | `domain-review-requesting`     |
| Respond to code review feedback       | `domain-review-receiving`      |
| Audit implementation against bd spec  | `work-audit`                 |
| Work in an isolated worktree          | `domain-git-worktrees`         |
| Finish a branch (merge/PR)            | `work-merge`      |
| Close epic + archive spec to done     | `spec-retro`                 |
| Start a new session                   | `meta-bootstrap`             |
| Write or edit a skill                 | `meta-skill-writing`         |

## Infinifu Skills (invocations)

Grouped by **kind** (process = flow-ordered step; util = toolbelt pulled in on demand; meta = infrastructure).

### Process — Layer 1 (epic .md lifecycle)

| Invocation                    | When to use                                                                        |
|-------------------------------|------------------------------------------------------------------------------------|
| `Skill(idea-brainstorming)`   | Before any creative work — features, components                                    |
| `Skill(idea-refactoring)`     | Refactor entry — identify smells, design refactor approach                         |
| `Skill(spec-writing)`         | Have requirements, need implementation spec                                        |
| `Skill(spec-refinement)`      | Review spec quality with SRE checklist before tasks are created                    |
| `Skill(spec-ready)`           | Create bd tasks + promote spec from `board/spec/` to `board/ready/`                |
| `Skill(spec-retro)`           | After merge — close bd epic, archive spec to `board/done/`                         |

### Process — Layer 2 (bd task execution)

| Invocation                    | When to use                                                                        |
|-------------------------------|------------------------------------------------------------------------------------|
| `Skill(plan-scrum-master)`    | Fully automated bd pipeline — agents implement, reviewer agent verifies            |
| `Skill(plan-supervised)`      | Agents implement in batches; user reviews each batch                               |
| `Skill(work-do)`              | Per-task protocol — handed a bd task ID, implement and close with evidence         |
| `Skill(work-audit)`           | Self-audit bd epic against spec contract before claiming done                      |
| `Skill(work-merge)`           | Implementation complete — merge / PR / cleanup                                      |

### Domain — toolbelt (pulled in on demand)

| Invocation                       | When to use                                                                      |
|----------------------------------|----------------------------------------------------------------------------------|
| `Skill(domain-tdd)`                | Before writing any implementation code — RED-GREEN-REFACTOR                      |
| `Skill(domain-verification)`       | About to claim any work is done — evidence before claims                         |
| `Skill(domain-bug-fixing)`         | Encountered a bug — full fix workflow                                            |
| `Skill(domain-debug)`              | Investigating a bug, test failure, or unexpected behavior                        |
| `Skill(domain-refactor-safely)`    | Refactoring code — small steps, tests between                                    |
| `Skill(domain-test-anti-patterns)` | Writing or changing tests, adding mocks                                          |
| `Skill(domain-test-effectiveness)` | Audit test quality and coverage                                                  |
| `Skill(domain-review-requesting)`  | Completed task, want an independent review                                        |
| `Skill(domain-review-receiving)`   | Received review feedback, before implementing suggestions                        |
| `Skill(domain-git-worktrees)`      | Need isolation from current workspace                                             |

### Meta — infrastructure

| Invocation                    | When to use                                                                        |
|-------------------------------|------------------------------------------------------------------------------------|
| `Skill(meta-bootstrap)`       | Start of every session — routes to relevant skills                                 |
| `Skill(meta-skill-writing)`   | Authoring or editing a skill                                                       |
| `Skill(meta-patterns)`        | Shared references (bd commands, writing patterns)                                  |

## Infinifu Agents (Task tool subagents)

| Agent                        | What it does                                             | Stage |
|------------------------------|----------------------------------------------------------|-------|
| `explore`                    | Fast codebase search — find files, search keywords       | any   |
| `codebase-investigator`      | Deep codebase understanding — patterns, architecture     | idea, spec |
| `internet-researcher`        | Fetch current info — API docs, library comparisons       | idea, spec |
| `general`                    | Multi-step autonomous tasks                              | any   |
| `scrum-master`                    | Orchestrate bd pipeline — dispatch and track agents      | plan  |
| `code-reviewer`              | Review completed work against plan and standards         | work  |
| `test-runner`                | Run tests/hooks/commits, return only summary + failures  | work  |
| `test-effectiveness-analyst` | Audit test quality — tautological, weak, missing         | work  |

## Command → Skill Reference

| Command                                  | What it does                        | Skill              |
|------------------------------------------|-------------------------------------|---------------------|
| `bd ready`                               | Show unblocked work                 | `spec-ready`        |
| `bd list --status in_progress`           | Show work in progress               | `spec-ready`        |
| `bd list --type epic --status open`      | Show active epics                   | `spec-ready`        |
| `bd create "..." --type epic`            | Create an epic                      | `spec-ready`        |
| `bd create "..." --type task`            | Create a task                       | `spec-ready`        |
| `bd create "..." --type bug`             | File a bug                          | `spec-ready`        |
| `bd show <id>`                           | View issue details                  | `spec-ready`        |
| `bd update <id> --status in_progress`    | Start working on a task             | `spec-ready`        |
| `bd update <id> --design "..."`          | Refine task spec                    | `spec-refinement`   |
| `bd close <id>`                          | Complete a task                     | `spec-ready`        |
| `bd dep add <child> <parent>`            | Add dependency                      | `spec-ready`        |
| `bd create "..." --parent <epic-id>`     | Create child with parent-child link | `spec-ready`        |
| `bd dep add <child> <parent> --type parent-child` | Legacy parent-child link (post-create) | `spec-ready`  |
| `bd dep tree <id> [--direction=up\|both]` | Per-issue dep view (default down = blockers) | `spec-ready` |
| `bd list --parent <epic-id>`             | List all children of an epic        | `spec-ready`        |
| `bd blocked`                             | Show blocked tasks                  | `spec-ready`        |
| `bd stats`                               | Overview statistics                 | `spec-ready`        |
| `git worktree add ...`                   | Create isolated worktree            | `domain-git-worktrees`|
| `gh pr create ...`                       | Create pull request                 | `work-merge` |

## Rename History

All skills were renamed to use lifecycle-stage prefixes (2026-03). See git history for the old-to-new mapping.
