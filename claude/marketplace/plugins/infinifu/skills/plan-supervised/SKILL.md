---
name: plan-supervised
description: Use when executing an approved plan in batches with the user reviewing each batch before the next. Under Pi, this is the sequential lifecycle path when no explicit multi-worker adapter is installed; under Claude's native branch, workers may still use the existing agent dispatch/resume semantics. Pick this for human-in-the-loop supervised execution; pick plan-scrum-master for fully automated Claude-native agent orchestration or future adapter-backed multi-worker orchestration.
---

# Supervised Plan Execution

## Overview

Load plan, review critically, execute tasks in runtime-appropriate batches, report for user review between batches.

**Core principle:** Batch execution with human checkpoints — the user reviews each batch before the next one starts.

**Announce at start:** "I'm using the plan-supervised skill to implement this plan."

## Prerequisites

### Runtime adapter gate

Follow the shared runtime-selection contract in
`../meta-patterns/runtime-adapter.md` before starting a batch.

- **Claude native branch:** if Claude's native agent surface is available, keep
  the existing background-worker path used by the Claude lifecycle: workers may
  be named, resumed, notified, audited, and merged through the Claude adapter.
- **Pi branch (`AI_AGENT=pi`):** when no explicit Pi multi-worker adapter is
  installed, run the batch sequentially in the current conversation: perform
  `work-do`, then `work-audit`, then let approved audits trigger `work-merge`
  before selecting the next task. Do not claim that Claude `Agent` subagents
  were dispatched, do not infer worker completion from tmux panes, and do not
  simulate Claude completion notifications.
- **Unsupported runtime:** if neither branch is available, stop with
  `unsupported-runtime` and name the lifecycle operation that cannot proceed.

A future Pi multi-worker adapter may replace the sequential Pi behavior only
when it explicitly provides worker dispatch, direct messaging, completion
notification, resume, and stop semantics without changing the bd/Git/AKM state
model.

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

For each task, follow the **`work-do`** per-task protocol: `bd show` → claim → name branch `bd-<id>.<N>` → implement via `domain-tdd` → log deviations immediately → record evidence in notes → report ready. `work-do` has the full checklist; don't reinvent it inline.

After the implementer reports ready, run **`work-audit`** to verify. On APPROVED, work-audit closes the task and auto-fires **`work-merge`** — per-task local land (merge `bd-<id>.<N>` into base, post-merge test, remove worktree, delete branch). If the just-closed task was the last open child of the epic, work-merge also runs the epic finale (AKM status flips + board→archive + bd close epic). All local — push is deferred to spec-retro.

After each task lands, run `bd ready` to find the next unblocked task.

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

After every task in the epic has been through work-audit (and thus work-merge), the **epic finale has already fired** as part of the last task's land — AKM statuses flipped, board → archive, bd epic closed. Nothing more to do at this layer for landing.

- bd 1.0 auto-exports `.beads/issues.jsonl` after each mutation; nothing extra needed to persist state.
- Announce: "All tasks landed; epic finale fired. Running spec-retro to refresh the AKM graph and push to remote."
- **REQUIRED SUB-SKILL:** Use `infinifu:spec-retro`
- Follow that skill to rewrite `im###` body, mint new ADRs / `ft###` updates / `us###` drafts as needed, then `git push` + `bd dolt push`.

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
- **infinifu:work-do** - Per-task protocol applied to each task in the batch (implementer side)
- **infinifu:work-audit** - Per-task verification gate after each implementer reports ready
- **infinifu:work-merge** - Per-task local land + epic finale, auto-triggered by work-audit on APPROVED
- **infinifu:spec-retro** - Post-epic AKM graph refresh + push to remote

**Alternative workflow:**
- **infinifu:plan-scrum-master** - Fully automated bd-driven pipeline dispatch with a reviewer agent (no per-batch user gate)
