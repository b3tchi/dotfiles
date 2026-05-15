# Breaking Down Large Tasks

**Load this reference when:** a task's effort estimate is >16 hours, or when you spot a task that bundles multiple independent deliverables.

## Why break tasks down

Tasks over 16 hours hide dependencies and fail to surface risk until you're deep in implementation. A 40-hour task rewritten as five 8-hour subtasks gives you five independently reviewable units, five places to stop and validate, and a much clearer picture of what "done" means at each stage.

Target size: 4–8 hours per subtask, 16 hours max per phase.

## The subtask recipe

Create each subtask with a complete design — don't defer specification to implementation time.

```bash
# Create first subtask
bd create "Subtask 1: [Specific Component]" \
  --type task \
  --priority 1 \
  --design "[Complete subtask design with all 7 categories addressed]"
# Returns bd-10

# Create second subtask
bd create "Subtask 2: [Another Component]" \
  --type task \
  --priority 1 \
  --design "[Complete subtask design]"
# Returns bd-11
```

## Linking subtasks to the parent

Prefer `bd create --parent <parent-id>` at creation time — the subtask is wired as a child atomically. Use a plain `bd dep add` only for sequencing (blocking order).

```bash
# Parent-child: done at creation (no separate dep add needed)
bd create "Subtask 1: ..." --type task --parent <parent-id> --design "..."
bd create "Subtask 2: ..." --type task --parent <parent-id> --design "..."

# Sequential link (do subtask 1 before subtask 2)
bd dep add <subtask-2-id> <subtask-1-id>

# Legacy — works but is two-step and error-prone:
# bd dep add <child-id> <parent-id> --type parent-child
```

## Converting the parent to a coordinator

Once a task is broken down, the parent stops being an implementation task and becomes a coordinator. Update its design to reflect that:

```bash
bd update bd-3 --design "$(cat <<'EOF'
## Goal
Coordinate implementation of [feature]. Broken into N subtasks.

## Success Criteria
- [ ] All N child subtasks closed
- [ ] Integration tests pass
- [ ] [High-level verification criteria — e.g., end-to-end flow succeeds]
EOF
)"
```

## Verify the new structure

```bash
bd list --parent <parent-id>                    # Every subtask under the parent
bd dep tree <subtask-id> --direction=both       # Per-subtask: what blocks it + what it blocks
```

Expect every subtask to appear under the parent and the blocking graph to match what you wrote. Circular dependencies surface when `bd dep tree` refuses to render — fix them before proceeding.

## When NOT to break down

Some tasks under 16 hours still benefit from staying together:

- The work is genuinely atomic (one focused change in one file)
- Splitting creates artificial seams that make review harder
- Subtasks would share so much context that the overhead of tracking them exceeds the benefit

Use judgment. The goal is reviewability and clear checkpoints, not task-count inflation.
