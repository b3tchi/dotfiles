# Installing Infinifu for OpenCode

Infinifu = lifecycle skills framework (idea → spec → plan → work → docs) + bd/beads task tracking.

## Prerequisites

- [OpenCode.ai](https://opencode.ai) installed
- Git installed
- [bd](https://github.com/steveyegge/beads) CLI installed (optional — needed for task tracking)
- bun or npm (for plugin dependencies)

## Quick Install

```bash
git clone <infinifu-repo-url> ~/.config/opencode/infinifu
~/.config/opencode/infinifu/install.sh
```

The install script will:
- Symlink the plugin into `~/.config/opencode/plugins/`
- Symlink skills into `~/.config/opencode/skills/infinifu/`
- Remove conflicting superpowers plugin if present (infinifu replaces it)
- Install plugin dependencies (`@opencode-ai/plugin`)

Restart OpenCode and verify by asking: *"do you have infinifu powers?"*

## Manual Install

If you prefer to do it by hand:

```bash
# 1. Clone
git clone <infinifu-repo-url> ~/.config/opencode/infinifu

# 2. Plugin — OpenCode scans ~/.config/opencode/plugins/ for .js files
mkdir -p ~/.config/opencode/plugins
ln -sf ~/.config/opencode/infinifu/plugins/infinifu.js \
       ~/.config/opencode/plugins/infinifu.js

# 3. Skills — OpenCode's skill tool scans ~/.config/opencode/skills/ for SKILL.md
mkdir -p ~/.config/opencode/skills
ln -sf ~/.config/opencode/infinifu/skills \
       ~/.config/opencode/skills/infinifu

# 4. Plugin dependency
cd ~/.config/opencode && bun install

# 5. Remove superpowers if installed (infinifu replaces it)
rm -f ~/.config/opencode/plugins/superpowers.js
rm -f ~/.config/opencode/skills/superpowers
```

## How It Works

**Plugin** (`infinifu.js`) uses `experimental.chat.system.transform` to inject bootstrap content into every session's system prompt. This includes the router skill, tool mapping, and bd orientation.

**Skills** are discovered by OpenCode's native `skill` tool, which recursively scans `~/.config/opencode/skills/` for directories containing `SKILL.md` files.

**Skill priority:** Project `.opencode/skills/` > Personal `~/.config/opencode/skills/` > Infinifu skills

## Usage

### Slash Commands

```
/idea-brainstorm-fnf         Start interactive design refinement
/spec-write-fnf              Create implementation spec
/plan-track-fnf              Create bd epic and tasks from spec
/plan-execute-fnf            Execute plan with checkpoints
/plan-dispatch-fnf           Dispatch agents to bd ready tasks
/work-review-fnf             Review against spec
/work-test-analyze-fnf       Audit test quality
/idea-refactor-fnf           Diagnose smells, design refactor
/work-refactor-execute-fnf   Execute refactor safely
/work-ship-fnf               Complete session — push, sync, hand off
```

### bd Task Tracking

Infinifu injects bd orientation at session start automatically:

```bash
bd ready                              # What's unblocked?
bd list --status in_progress          # Anything mid-flight?
bd list --type epic --status open     # Active epics?
```

### Personal Skills

Add your own skills alongside infinifu:

```bash
mkdir -p ~/.config/opencode/skills/my-skill
# Create ~/.config/opencode/skills/my-skill/SKILL.md
```

## Updating

```bash
cd ~/.config/opencode/infinifu && git pull
```

## Troubleshooting

### Plugin not loading

```bash
# Check symlink
ls -l ~/.config/opencode/plugins/infinifu.js

# Check plugin dependency
ls ~/.config/opencode/node_modules/@opencode-ai/plugin

# Check OpenCode sees it
opencode debug config | grep infinifu
```

### Skills not found

```bash
# Check symlink
ls -l ~/.config/opencode/skills/infinifu

# List discovered skills
opencode debug skill
```

### Conflicts with superpowers

Infinifu replaces superpowers. If both are installed, the bootstrap will be injected twice. Remove superpowers:

```bash
rm -f ~/.config/opencode/plugins/superpowers.js
rm -f ~/.config/opencode/skills/superpowers
```
