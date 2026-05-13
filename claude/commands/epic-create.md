---
description: Create or resume a brainstorm epic (bd epic + idea file + claude session metadata)
argument-hint: <name>
allowed-tools: Bash(epic create:*)
---

Create or resume the brainstorm epic named `$1`.

This writes the bd epic and `board/idea/<name>.<short>.md`, but does **not** launch a nested `claude` session — that has to happen from a terminal/tmux pane outside this session. The script prints the exact `claude --resume` / `claude --session-id` command to use.

!`epic create $1 --no-launch`

After running:
- Confirm in one line which epic was created or resumed (name, bd id).
- Surface the `claude ... -n <label>` invocation so the user can copy-paste it into a fresh tmux pane.
