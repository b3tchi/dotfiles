# bd Command Reference

Common bd commands used across multiple skills. Reference this instead of duplicating.

Targets **bd 1.0+**. Key differences from bd 0.50: `bd sync` is removed (auto-export writes `.beads/issues.jsonl` after every mutation — just `git add .beads/`); issue IDs use a hash-suffix form (e.g. `bd-9bd`, `bd-b4u`) rather than sequential numbers; `bd create --parent <epic-id>` creates the parent-child link atomically.

## Reading Issues

```bash
# Show single issue with full design
bd show <issue-id>

# List all open issues
bd list --status open

# List closed issues
bd list --status closed

# List every child of an epic (authoritative view of the epic's tasks)
bd list --parent <epic-id>

# Dependency tree for a specific issue — defaults to DOWN (what blocks this issue)
#   - down: blockers of this issue (default)
#   - up:   issues this one blocks (dependents)
#   - both: full graph
bd dep tree <issue-id>                    # blockers of <issue-id>
bd dep tree <issue-id> --direction=up     # what <issue-id> blocks
bd dep tree <issue-id> --direction=both   # full graph
# Note: bd dep tree <epic-id> without flags shows just the epic; use bd list --parent to see children.

# Find tasks ready to work on (no blocking dependencies)
bd ready
```

## Creating Issues

```bash
# Create epic
bd create "Epic: Feature Name" \
  --type epic \
  --priority [0-4] \
  --design "## Goal
[Epic description]

## Success Criteria
- [ ] All phases complete
..."

# Create feature/phase (child of an epic in one step)
bd create "Phase 1: Phase Name" \
  --type feature \
  --priority [0-4] \
  --parent <epic-id> \
  --design "[Phase design]"

# Create task (child of an epic in one step — no separate bd dep add needed)
bd create "Task Name" \
  --type task \
  --priority [0-4] \
  --parent <epic-id> \
  --design "[Task design]"
```

`--parent` attaches the new issue to its parent via a `parent-child` dependency atomically. Use it instead of a separate `bd dep add <child> <parent> --type parent-child` call.

## Updating Issues

```bash
# Update issue design (detailed spec/requirements)
bd update bd-3 --design "$(cat <<'EOF'
[Complete updated design]
EOF
)"

# Add notes (audit trail — review feedback, rejection reasons, progress)
bd update bd-3 --notes "Rejected: missing progress reporting. Need to add report every 100 items."
```

**IMPORTANT**: Use `--design` for the full detailed description, NOT `--description` (which is title only).

**Field usage:**
- `--design` — the spec/requirements (what to build, updated on rejection with new conditions)
- `--notes` — audit trail (track review feedback, rejection reasons, progress across attempts)
- `--description` — title only, rarely used

## Managing Status

```bash
# Start working on task
bd update bd-3 --status in_progress

# Complete task
bd close bd-3

# Reopen task
bd update bd-3 --status open
```

**Common Mistakes:**
```bash
# ❌ WRONG - bd status shows database overview, doesn't change status
bd status bd-3 --status in_progress

# ✅ CORRECT - use bd update to change status
bd update bd-3 --status in_progress

# ❌ WRONG - using hyphens in status values
bd update bd-3 --status in-progress

# ✅ CORRECT - use underscores in status values
bd update bd-3 --status in_progress

# ❌ WRONG - 'done' is not a valid status
bd update bd-3 --status done

# ✅ CORRECT - use bd close to complete
bd close bd-3
```

**Valid status values:** `open`, `in_progress`, `blocked`, `closed`

## Managing Dependencies

```bash
# Add blocking dependency (LATER depends on EARLIER)
# Syntax: bd dep add <dependent> <dependency>
bd dep add <later-id> <earlier-id>   # <later-id> waits on <earlier-id>

# Parent-child: prefer `bd create --parent <parent-id>` at creation time.
# If you must link after the fact:
bd dep add <child-id> <parent-id> --type parent-child

# View dependency tree for a given issue (see Reading Issues — defaults to DOWN).
bd dep tree <issue-id>
bd dep tree <issue-id> --direction=up     # what this issue blocks
bd dep tree <issue-id> --direction=both   # full graph

# Prefer `bd list --parent <epic-id>` to enumerate children of an epic —
# `bd dep tree <epic-id>` without --direction shows only the epic node.
```

## Persistence

bd 1.0 writes to `.beads/` (Dolt DB) on every mutation and auto-exports the flattened view to `.beads/issues.jsonl` within ~60s (throttled). There is **no `bd sync` command** — if you need the JSONL refreshed immediately (e.g. before committing in a script), call `bd export -o .beads/issues.jsonl`. Normal flow is: mutate → `git add .beads/` → commit.

```bash
# Force-export immediately (rare — only needed if you can't wait for the throttle)
bd export -o .beads/issues.jsonl
```

## Commit Message Format

Reference bd task IDs in commits (use infinifu:test-runner agent):

```bash
# Use test-runner agent to avoid pre-commit hook pollution
Dispatch infinifu:test-runner agent: "Run: git add <files> && git commit -m 'feat(bd-3): implement feature

Implements step 1 of bd-3: Task Name
'"
```

## Common Queries

```bash
# Check if all tasks in epic are closed
bd list --status open --parent bd-1
# Output: [empty] = all closed

# See what's blocking current work
bd ready  # Shows only unblocked tasks

# Find all in-progress work
bd list --status in_progress
```
