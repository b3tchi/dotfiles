/**
 * Infinifu plugin for OpenCode.ai
 *
 * Lifecycle skills framework with bd (beads) task tracking.
 * Injects bootstrap context via system prompt transform.
 * Skills are discovered via OpenCode's native skill tool from symlinked directory.
 */

import path from 'path';
import fs from 'fs';
import os from 'os';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Simple frontmatter extraction
const extractAndStripFrontmatter = (content) => {
  const match = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return { frontmatter: {}, content };

  const frontmatterStr = match[1];
  const body = match[2];
  const frontmatter = {};

  for (const line of frontmatterStr.split('\n')) {
    const colonIdx = line.indexOf(':');
    if (colonIdx > 0) {
      const key = line.slice(0, colonIdx).trim();
      const value = line.slice(colonIdx + 1).trim().replace(/^["']|["']$/g, '');
      frontmatter[key] = value;
    }
  }

  return { frontmatter, content: body };
};

// Normalize a path: trim whitespace, expand ~, resolve to absolute
const normalizePath = (p, homeDir) => {
  if (!p || typeof p !== 'string') return null;
  let normalized = p.trim();
  if (!normalized) return null;
  if (normalized.startsWith('~/')) {
    normalized = path.join(homeDir, normalized.slice(2));
  } else if (normalized === '~') {
    normalized = homeDir;
  }
  return path.resolve(normalized);
};

export const InfinifuPlugin = async ({ client, directory }) => {
  const homeDir = os.homedir();
  const infinifuDir = path.resolve(__dirname, '..');
  const skillsDir = path.join(infinifuDir, 'skills');
  const envConfigDir = normalizePath(process.env.OPENCODE_CONFIG_DIR, homeDir);
  const configDir = envConfigDir || path.join(homeDir, '.config/opencode');

  // Load a skill file and strip frontmatter
  const loadSkill = (skillName) => {
    const skillPath = path.join(skillsDir, skillName, 'SKILL.md');
    if (!fs.existsSync(skillPath)) return null;
    const fullContent = fs.readFileSync(skillPath, 'utf8');
    const { content } = extractAndStripFrontmatter(fullContent);
    return content;
  };

  // Generate combined bootstrap content
  const getBootstrapContent = () => {
    const bootstrapContent = loadSkill('meta-bootstrap');
    if (!bootstrapContent) return null;

    const toolMapping = `**Tool Mapping for OpenCode:**
When skills reference tools you don't have, substitute OpenCode equivalents:
- \`TodoWrite\` → \`update_plan\`
- \`Task\` tool with subagents → Use OpenCode's subagent system (@mention)
- \`Skill\` tool → OpenCode's native \`skill\` tool
- \`Read\`, \`Write\`, \`Edit\`, \`Bash\` → Your native tools

**Skills location:**
Infinifu skills are in \`${configDir}/skills/infinifu/\`
Use OpenCode's native \`skill\` tool to list and load skills.`;

    const bdIntegration = `**bd (Beads) Task Tracking - ALWAYS USE FOR MULTI-STEP WORK:**
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
- File discovered issues: \`bd create "Discovered: ..." --type task\`

Load the \`spec-ready\` skill for the complete bd workflow reference.
bd issues persist across sessions -- they are your long-term memory.`;

    return `<EXTREMELY_IMPORTANT>
You have infinifu powers (lifecycle skills + beads task tracking).

**IMPORTANT: The meta-bootstrap skill content is included below. It is ALREADY LOADED - you are currently following it. Do NOT use the skill tool to load "meta-bootstrap" again.**

${bootstrapContent}

${toolMapping}

${bdIntegration}
</EXTREMELY_IMPORTANT>`;
  };

  return {
    'experimental.chat.system.transform': async (_input, output) => {
      const bootstrap = getBootstrapContent();
      if (bootstrap) {
        (output.system ||= []).push(bootstrap);
      }
    }
  };
};
