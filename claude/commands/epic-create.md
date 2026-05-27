---
description: Mint a brainstorm spec (sp### zettel + board.md entry + claude session id)
argument-hint: <name>
allowed-tools: Bash(akm create:*)
---

Create the brainstorm sp### zettel from `$ARGUMENTS`.

This writes `docs/notes/spec/sp###.md` at `status: idea` and inserts a wikilink under `docs/board.md ## idea`. A claude session id is minted into the zettel's frontmatter so the brainstorm can be resumed in a fresh pane via `claude --session-id <id>`.

bd epic / task creation happens later in the lifecycle (`spec-ready` skill when the spec is ready for execution) — not here. Profile handling (`CLAUDE_CONFIG_DIR=...`) is left to the user; prefix it manually when copying the resume command.

!`akm create $ARGUMENTS --session`

After running:
- Confirm in one line which sp### was minted (id, name).
- Surface the full `claude --session-id <id> -n <name>.<sp###>` invocation so the user can copy-paste it into a fresh tmux pane.
