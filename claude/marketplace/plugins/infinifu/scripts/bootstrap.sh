#!/usr/bin/env bash
set -euo pipefail

# Infinifu bootstrap — injected at session start via SessionStart hook.
# Outputs meta-bootstrap skill content + tool mapping + bd integration.
# Uses hookSpecificOutput JSON format for proper Claude Code integration.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFINIFU_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$INFINIFU_DIR/skills/meta-bootstrap/SKILL.md"

# Strip YAML frontmatter (everything between first --- and second ---)
strip_frontmatter() {
  sed -n '/^---$/,/^---$/!p' "$1" 2>/dev/null || cat "$1"
}

# --- Output bootstrap content ---

if [ ! -f "$SKILL_FILE" ]; then
  echo "WARNING: meta-bootstrap skill not found at $SKILL_FILE" >&2
  exit 0
fi

BOOTSTRAP_CONTENT="$(strip_frontmatter "$SKILL_FILE")"

SESSION_CONTEXT="<EXTREMELY_IMPORTANT>
You have infinifu powers (lifecycle skills + beads task tracking).

**IMPORTANT: The meta-bootstrap skill content is included below. It is ALREADY LOADED - you are currently following it. Do NOT use the Skill tool to load \"meta-bootstrap\" again.**

${BOOTSTRAP_CONTENT}

**Tool Mapping for Claude Code:**
When skills reference tools, use these Claude Code equivalents:
- \`TodoWrite\` → \`TaskCreate\` / \`TaskUpdate\` (Claude Code's task tracking)
- \`Task\` tool with subagents → \`Agent\` tool with \`subagent_type\` parameter
- \`Skill\` tool → Claude Code's native \`Skill\` tool
- \`Read\`, \`Write\`, \`Edit\`, \`Bash\`, \`Glob\`, \`Grep\` → Your native tools

**bd (Beads) Task Tracking - ALWAYS USE FOR MULTI-STEP WORK:**
You have the \`bd\` CLI available for hierarchical task management.
At the START of every session, orient yourself:
\`\`\`bash
bd ready                              # What's unblocked?
bd list --status in_progress          # Anything mid-flight?
bd list --type epic --status open     # Active epics?
\`\`\`

**Use bd instead of flat checklists for all planning and execution:**
- Create epics with \`bd create --type epic\`
- Create tasks with dependencies via \`bd dep add\`
- Track status: \`bd update <id> --status in_progress\` / \`bd close <id>\`
- Find next work: \`bd ready\`
- File discovered issues: \`bd create \"Discovered: ...\" --type task\`

Load the \`spec-ready\` skill for the complete bd workflow reference.
bd issues persist across sessions -- they are your long-term memory.
</EXTREMELY_IMPORTANT>"

# Escape for JSON embedding
escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

escaped_context=$(escape_for_json "$SESSION_CONTEXT")

# Output as hookSpecificOutput JSON for Claude Code
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$escaped_context"

exit 0
