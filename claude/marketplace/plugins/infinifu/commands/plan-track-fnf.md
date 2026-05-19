---
description: Create bd epic and tasks from an implementation plan
disable-model-invocation: true
---

Before doing anything else, print this phase banner exactly:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PHASE: TRACK
  Setting up bd issues from plan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Then invoke the infinifu:spec-ready skill.

Your job:
1. Find the most recent plan in docs/plans/
2. Create a bd epic for the feature with full goal and success criteria in -d
3. Create a task for each step in the plan, with full context in -d (requirements, acceptance criteria, file paths)
4. Set up parent-child relationships to the epic
5. Set up sequential dependencies between tasks
6. Verify with `bd dep tree` and `bd ready`
7. Report the epic ID and task count
