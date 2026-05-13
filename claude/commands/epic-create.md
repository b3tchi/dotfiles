---
description: Create or resume a brainstorm epic and open it in a new tmux window
argument-hint: <name>
allowed-tools: Bash(epic create:*)
---

Create or resume the brainstorm epic named `$ARGUMENTS`.

Writes the bd epic and `board/idea/<name>.<short>.md`, then spawns a new tmux window running the dedicated `claude` session for this epic. Requires running from inside tmux.

!`epic create $ARGUMENTS --new-window`

After running, confirm in one line: epic name, bd id, and the tmux window label the new claude session opened in.
