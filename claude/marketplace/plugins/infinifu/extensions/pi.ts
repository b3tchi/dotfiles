import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const bootstrapPath = join(pluginRoot, "skills", "meta-bootstrap", "SKILL.md");

function stripFrontmatter(content: string): string {
  return content.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "");
}

const bootstrap = stripFrontmatter(readFileSync(bootstrapPath, "utf8"));

const piMapping = `
**Tool mapping for Pi:**
- Infinifu references such as \`infinifu:domain-tdd\` mean Pi skill \`domain-tdd\`.
- Load a skill by reading its listed \`SKILL.md\`, or let the user invoke \`/skill:<name>\`.
- \`TodoWrite\`, \`TaskCreate\`, and \`TaskUpdate\` → use the \`bd\` CLI. Never create markdown TODO lists.
- \`Read\`, \`Write\`, \`Edit\`, \`Bash\`, \`Glob\`, and \`Grep\` → use Pi's native read, write, edit, bash, find, and grep tools.
- Runtime-specific lifecycle behavior follows \`infinifu:meta-patterns/runtime-adapter.md\`: \`AI_AGENT=pi\` selects Pi, Claude's native Agent/Task surface selects Claude behavior, and unknown runtimes fail closed.
- Claude \`Agent\`/\`Task\` subagents are not built into Pi. Use independent Pi processes in tmux only when a Pi runtime adapter provides a direct messaging contract; otherwise execute sequentially. Never pretend a subagent was dispatched.

**bd task tracking:**
Use \`bd\` for multi-step work. Start with \`bd prime\` for current commands and workflow. Track status and discovered work in bd; follow the repository's AGENTS.md completion protocol.
`;

export default function infinifu(pi: ExtensionAPI): void {
  pi.on("before_agent_start", (event) => ({
    systemPrompt: `${event.systemPrompt}\n\n<EXTREMELY_IMPORTANT>\nYou have Infinifu lifecycle skills and bd task tracking. The meta-bootstrap skill is already loaded below; do not load it again.\n\n${bootstrap}\n\n${piMapping}\n</EXTREMELY_IMPORTANT>`,
  }));
}
