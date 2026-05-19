---
description: Complete session - push, sync bd, clean up, hand off
disable-model-invocation: true
---

Before doing anything else, print this phase banner exactly:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PHASE: MERGE
  Landing the branch
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Then invoke the infinifu:work-merge skill and follow it exactly.

Mandatory steps:
1. File bd issues for any remaining work
2. Run quality gates (tests, linters, builds) if code changed
3. Update all bd issue statuses (close finished, update in-progress)
4. Sync and push:
   ```bash
   bd sync
   git pull --rebase
   git add -A
   git commit -m "chore: session end - <summary>"
   git push
   ```
5. Verify: `git status` must show "up to date with origin"
6. Clean up stashes and remote branches if needed
7. Provide handoff context for next session:
   - Current epic and status
   - What `bd ready` shows
   - Any blockers or notes
