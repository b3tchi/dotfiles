---
name: plan-supervised
description: Use when executing an approved plan in batches with the user reviewing each batch before the next — the agent does the implementation, reports at each checkpoint, waits for user feedback before continuing. Pick this for human-in-the-loop supervised execution; pick plan-scrum-master for fully automated agent orchestration with an automated reviewer.
---

# Supervised Plan Execution

## Overview

Load plan, review critically, execute tasks in batches, report for user review between batches.

**Core principle:** Batch execution with human checkpoints — the user reviews each batch before the next one starts.

**Announce at start:** "I'm using the plan-supervised skill to implement this plan."

## Prerequisites

Before using this skill, TWO mandatory gates must have been passed:

1. **⛔ Spec approved by user** — the spec/plan document was reviewed and explicitly approved
2. **⛔ bd tasks approved by user** — the bd task list was reviewed and explicitly approved

If either gate was not passed, STOP and go back. Do NOT start execution without both approvals.

## The Process

### Step 1: Load and Review Plan
1. Read plan file
2. Orient with bd: `bd ready` and `bd list --status in_progress`
3. Verify both gates were passed (spec approved + bd tasks approved)
4. Review critically - identify any questions or concerns about the plan
5. If concerns: Raise them with your human partner before starting
6. If no concerns: Proceed with first ready task from `bd ready`

### Step 2: Execute Batch
**Default: First 3 tasks**

For each task, follow the **`work-do`** per-task protocol: `bd show` → claim → implement via `domain-tdd` → log deviations immediately → close with evidence → report. `work-do` has the full checklist; don't reinvent it inline.

After each task closes, run `bd ready` to find the next unblocked task.

### Step 3: Report
When batch complete:
- Show what was implemented
- Show verification output
- Say: "Ready for feedback."

### Step 4: Continue
Based on feedback:
- Apply changes if needed
- Execute next batch
- Repeat until complete

### Step 5: Complete Development

After all tasks complete and verified:
- bd 1.0 auto-exports `.beads/issues.jsonl` after each mutation; nothing extra needed to persist state.
- Announce: "I'm using the work-merge skill to complete this work."
- **REQUIRED SUB-SKILL:** Use infinifu:work-merge
- Follow that skill to verify tests, present options, execute choice

## When to Stop and Ask for Help

**STOP executing immediately when:**
- Hit a blocker mid-batch (missing dependency, test fails, instruction unclear)
- Plan has critical gaps preventing starting
- You don't understand an instruction
- Verification fails repeatedly

**Ask for clarification rather than guessing.**

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- Partner updates the plan based on your feedback
- Fundamental approach needs rethinking

**Don't force through blockers** - stop and ask.

## Remember
- Review plan critically first
- Follow plan steps exactly
- Don't skip verifications
- Reference skills when plan says to
- Between batches: just report and wait
- Stop when blocked, don't guess
- Never start implementation on main/master branch without explicit user consent

## Integration

**Required workflow skills:**
- **infinifu:domain-git-worktrees** - REQUIRED: Set up isolated workspace before starting
- **infinifu:spec-writing** - Creates the plan this skill executes
- **infinifu:work-do** - Per-task protocol applied to each task in the batch
- **infinifu:work-merge** - Complete development after all tasks

**Alternative workflow:**
- **infinifu:plan-scrum-master** - Fully automated bd-driven pipeline dispatch with a reviewer agent (no per-batch user gate)
