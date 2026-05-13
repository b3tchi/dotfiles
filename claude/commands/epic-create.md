---
description: Create or resume a brainstorm epic (bd epic + idea file + claude session metadata)
argument-hint: <name> [--profile personal|work]
allowed-tools: Bash(epic create:*)
---

Create or resume the brainstorm epic from `$ARGUMENTS`.

Pass an optional `--profile personal` or `--profile work` to control which Claude account (`$CLAUDE_CONFIG_DIR`) the resume command will target. Without a profile, the current account is used.

This writes the bd epic and `board/idea/<name>.<short>.md`, but does **not** launch a nested `claude` session — that has to happen from a terminal/tmux pane outside this session. The script prints the exact `claude --resume` / `claude --session-id` invocation, including a `CLAUDE_CONFIG_DIR=...` prefix when a profile is set.

!`epic create $ARGUMENTS --no-launch`

After running:
- Confirm in one line which epic was created or resumed (name, bd id, profile if any).
- Surface the full `[CLAUDE_CONFIG_DIR=...] claude ... -n <label>` invocation so the user can copy-paste it into a fresh tmux pane.
