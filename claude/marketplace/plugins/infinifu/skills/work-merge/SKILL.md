---
name: work-merge
description: Use when implementation is complete, work-audit has approved it, and you need to land the branch — guides the final integration step by presenting structured options for merge, PR, or cleanup. The "merge" here covers the whole landing phase: quality gates, commit, push, and handoff, not just the git merge command. Called after work-audit and before spec-retro.
---

# Merge / Land the Branch

## Overview

Guide completion of development work by presenting clear options and handling chosen workflow.

**Core principle:** Verify tests → Present options → Execute choice → Clean up.

**Announce at start:** "I'm using the work-merge skill to complete this work."

## AKM hooks

Stage 7 of the AKM lifecycle — see `claude/akm/akm-lifecycle.md` for the full map and `claude/akm/akm.md` for typed-zettel schemas. Status flips and archive move.

**Reads:** `sp###`, `us###`, `im###`.

**Writes:**

- `us###.status` → `done`.
- `im###.status` → `accepted`. (The body narrative may still reflect `proposed`; stage 8 `spec-retro` rewrites it to shipped reality.)
- `sp###.status` → `done`. Flip the footer `Index: [[board]]` → `Index: [[archive]]`.
- `board.md` — remove `[[sp###]]` from `## ready`.
- `archive.md` — add `[[sp###]]` under `## done`.
- Close the beads task / bug.

## The Process

### Step 1: Verify Tests

**Before presenting options, verify tests pass:**

```bash
# Run project's test suite
npm test / cargo test / pytest / go test ./...
```

**If tests fail:**
```
Tests failing (<N> failures). Must fix before completing:

[Show failures]

Cannot proceed with merge/PR until tests pass.
```

Stop. Don't proceed to Step 2.

**If tests pass:** Continue to Step 2.

### Step 2: Determine Base Branch

```bash
# Try common base branches
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
```

Or ask: "This branch split from main - is that correct?"

### Step 3: Present Options

Present exactly these 4 options:

```
Implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)
4. Discard this work

Which option?
```

**Don't add explanation** - keep options concise.

### Step 4: Execute Choice

#### Option 1: Merge Locally

```bash
# Switch to base branch
git checkout <base-branch>

# Pull latest
git pull

# Merge feature branch
git merge <feature-branch>

# Verify tests on merged result
<test command>

# If tests pass
git branch -d <feature-branch>
```

Then: Cleanup worktree (Step 5)

#### Option 2: Push and Create PR

```bash
# Push branch
git push -u origin <feature-branch>

# Create PR
gh pr create --title "<title>" --body "$(cat <<'EOF'
## Summary
<2-3 bullets of what changed>

## Test Plan
- [ ] <verification steps>
EOF
)"
```

Then: Cleanup worktree (Step 5)

#### Option 3: Keep As-Is

Report: "Keeping branch <name>. Worktree preserved at <path>."

**Don't cleanup worktree.**

#### Option 4: Discard

**Confirm first:**
```
This will permanently delete:
- Branch <name>
- All commits: <commit-list>
- Worktree at <path>

Type 'discard' to confirm.
```

Wait for exact confirmation.

If confirmed:
```bash
git checkout <base-branch>
git branch -D <feature-branch>
```

Then: Cleanup worktree (Step 5)

### Step 5: Cleanup Worktree

**For Options 1, 2, 4:**

Check if in worktree:
```bash
git worktree list | grep $(git branch --show-current)
```

If yes:
```bash
git worktree remove <worktree-path>
```

**For Option 3:** Keep worktree.

### Step 6: Close Epic and Archive Board Document

**For Options 1 and 2 (merge or PR):**

Use `infinifu:spec-retro` — closes the bd epic and moves the spec from `board/ready/` to `board/done/`.

**For Options 3 and 4:** Skip — work is not complete (kept as-is or discarded).

## Quick Reference

| Option | Merge | Push | Keep Worktree | Cleanup Branch | Archive Board |
|--------|-------|------|---------------|----------------|---------------|
| 1. Merge locally | ✓ | - | - | ✓ | spec-retro |
| 2. Create PR | - | ✓ | ✓ | - | spec-retro |
| 3. Keep as-is | - | - | ✓ | - | - |
| 4. Discard | - | - | - | ✓ (force) | - |

## Common Mistakes

**Skipping test verification**
- **Problem:** Merge broken code, create failing PR
- **Fix:** Always verify tests before offering options

**Open-ended questions**
- **Problem:** "What should I do next?" → ambiguous
- **Fix:** Present exactly 4 structured options

**Automatic worktree cleanup**
- **Problem:** Remove worktree when might need it (Option 2, 3)
- **Fix:** Only cleanup for Options 1 and 4

**No confirmation for discard**
- **Problem:** Accidentally delete work
- **Fix:** Require typed "discard" confirmation

## Red Flags

**Never:**
- Proceed with failing tests
- Merge without verifying tests on result
- Delete work without confirmation
- Force-push without explicit request

**Always:**
- Verify tests before offering options
- Present exactly 4 options
- Get typed confirmation for Option 4
- Clean up worktree for Options 1 & 4 only

## Integration

**Called by:**
- **plan-scrum-master** - After all pipeline tasks complete
- **plan-supervised** - After all batches complete

**Pairs with:**
- **domain-git-worktrees** - Cleans up worktree created by that skill
- **spec-retro** - Called after Options 1 & 2 to close epic and archive spec
