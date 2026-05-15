# Infinifu

A plugin providing lifecycle-driven skills (idea, spec, plan, work, docs) with bd/beads task tracking — structured workflows for AI coding agents.

Works with both **Claude Code** and **OpenCode.ai**.

Infinifu gives your AI coding agent structured workflows, persistent task tracking, and specialized agents — so it follows proven development patterns instead of ad-hoc guessing.

## How It Works

Infinifu injects itself into every session via bootstrap injection. The agent automatically:

1. Checks for relevant skills before any task (even at 1% probability)
2. Follows mandatory workflows — idea-brainstorming before coding, TDD, domain-verification before completion
3. Uses `bd` (beads) for persistent hierarchical task tracking across sessions
4. Dispatches specialized agents for code review, testing, research, and investigation

## Process Flow

The core development workflow chains skills together automatically:

```
                    Session Start
                         |
                         v
               meta-bootstrap (router)
              "Does a skill apply?" -----> debugging / refactoring / etc.
                         |
                    creative work
                         |
                         v
                  idea-brainstorming
            Refine idea -> propose approaches
              -> present design for approval
                         |
                         v
                    spec-writing
            Define precisely what to build
              -> implementation spec
                         |
                         v
                   spec-refinement
            SRE review: granularity, edge cases,
              test meaningfulness (if non-trivial)
                         |
                         v
                   plan-prepare
            spec-ready: create epic, tasks,
              deps, parallelism, blockers
                         |
                         v
                   plan-dispatch
            plan-scrum-master (automated)
            or plan-supervised (user reviews)
                         |
                         v
            work-audit
            Verify against spec with
              SRE-level scrutiny
                         |
                    APPROVED? ---no---> STOP, fix gaps
                         |
                        yes
                         |
                         v
              work-merge
            Close bd tasks, merge / PR / cleanup
```

**Cross-cutting skills used throughout:**

- **domain-tdd** — strict RED-GREEN-REFACTOR during all implementation
- **spec-ready** — persistent task tracking replaces flat checklists
- **domain-git-worktrees** — isolated workspaces for development
- **domain-verification** — evidence before claims, always

## Installation

### Prerequisites

- [Claude Code](https://claude.ai/code) and/or [OpenCode.ai](https://opencode.ai) installed
- Git installed
- [jq](https://jqlang.github.io/jq/) installed (for Claude Code hook setup)
- [bd](https://github.com/steveyegge/beads) CLI installed (optional — needed for task tracking)

### Setup

```bash
git clone <repo-url> ~/infinifu
~/infinifu/install.sh
```

The installer auto-detects which tools are available (`~/.claude/` and/or `~/.config/opencode/`) and installs for all of them:

- **Claude Code** — symlinks skills, commands, agents into `~/.claude/` and adds a SessionStart hook for bootstrap injection
- **OpenCode** — symlinks JS plugin, skills, commands, agents into `~/.config/opencode/` and installs plugin dependencies

Claude Code can also load infinifu directly as a plugin:

```bash
claude --plugin-dir ~/infinifu
```

### Verify

Restart your tools and ask: *"do you have infinifu powers?"*

### Updating

```bash
cd ~/infinifu && git pull
```

### Uninstalling

```bash
~/infinifu/install.sh uninstall
```

Removes symlinks and hooks from all detected targets.

## Slash Commands

| Command | Description | Stage |
|---------|-------------|-------|
| `/idea-brainstorm-fnf` | Interactive design refinement before any creative work | idea |
| `/spec-write-fnf` | Create detailed implementation spec with bite-sized tasks | spec |
| `/plan-track-fnf` | Create bd epic and tasks from spec | plan |
| `/plan-execute-fnf` | Execute plan in batches with review checkpoints | plan |
| `/plan-dispatch-fnf` | Dispatch agents to bd ready tasks — scrum master pipeline | plan |
| `/work-review-fnf` | Review implementation against spec | work |
| `/work-test-analyze-fnf` | Audit test quality — tautological tests, coverage gaming | work |
| `/idea-refactor-fnf` | Diagnose smells, design refactor approach | idea |
| `/work-refactor-execute-fnf` | Execute a refactor safely with tests staying green | work |
| `/work-ship-fnf` | Complete session — push, sync bd, clean up, hand off | work |

## Agents

| Agent | Model | Purpose |
|-------|-------|---------|
| **test-runner** | haiku | Run tests/hooks/commits in isolated context, return summary only |
| **code-reviewer** | inherit | Review code against plans and standards |
| **codebase-investigator** | haiku | Deep-dive into codebase to find patterns and verify assumptions |
| **internet-researcher** | haiku | Research APIs, libraries, and best practices |
| **test-effectiveness-analyst** | default | Audit test quality with SRE-level scrutiny |
| **scrum-master** | inherit | Orchestrate bd pipeline — dispatch agents to ready tasks |

## Skills

### Idea
- **idea-brainstorming** — Socratic design refinement before code

### Spec
- **spec-writing** — Detailed TDD implementation plans
- **spec-refinement** — Ensure all corner cases are covered (SRE checklist)

### Plan
- **spec-ready** — bd basics: epics, tasks, dependencies, ready queue
- **plan-scrum-master** — Fully automated orchestrator: agents implement, reviewer agent verifies
- **plan-supervised** — Agents implement in batches; user reviews each batch (human-in-the-loop)
- **work-do** — Per-task protocol: given a bd task ID, implement and close with evidence (invoked by both dispatchers above)

### Work: Code & TDD
- **domain-tdd** — RED-GREEN-REFACTOR, no exceptions
- **domain-bug-fixing** — Full workflow from discovery to closure

### Work: Debug
- **domain-debug** — 4-phase investigation (evidence → hypothesis → test → fix); bundles root-cause tracing, defense-in-depth, debugger references, and polluter-finding

### Idea: Refactor
- **idea-refactoring** — Diagnose smells, design refactor approach

### Work: Refactor
- **domain-refactor-safely** — Small steps with tests staying green

### Work: Test
- **domain-test-anti-patterns** — Common testing mistakes to avoid
- **domain-test-effectiveness** — Audit test quality
- **domain-verification** — Evidence before claims

### Work: Review
- **domain-review-requesting** — Request reviews with structured template
- **domain-review-receiving** — Handle feedback with technical rigor
- **work-audit** — Verify implementation matches spec

### Work: Git
- **domain-git-worktrees** — Isolated development branches
- **work-merge** — PR creation and cleanup

### Meta
- **meta-bootstrap** — Router skill (auto-injected at session start)
- **meta-skill-writing** — Create new skills following best practices
- **meta-patterns** — Shared references (bd commands, anti-patterns)

## File Structure

```
infinifu/
├── .claude-plugin/
│   └── plugin.json                # Claude Code plugin manifest
├── .opencode/
│   └── INSTALL.md
├── agents/                        # 6 specialized agents
├── commands/                      # 10 slash commands
├── hooks/
│   └── hooks.json                 # Claude Code SessionStart hook
├── plugins/
│   └── infinifu.js                # OpenCode plugin
├── scripts/
│   └── bootstrap.sh               # Bootstrap content generator
└── skills/                        # 24 skill directories
    ├── idea-brainstorming/        #   idea stage
    ├── idea-refactoring/          #   idea: refactor entry point
    ├── spec-writing/              #   spec stage
    ├── spec-refinement/
    ├── spec-ready/                #   plan stage
    ├── plan-scrum-master/
    ├── plan-supervised/
    ├── work-do/                   #   work stage (process: per-task)
    ├── work-audit/                #   work stage (process: epic self-check)
    ├── work-merge/                #   work stage (process: land the branch)
    ├── domain-tdd/                  #   util (pulled in on demand)
    ├── domain-verification/
    ├── domain-bug-fixing/
    ├── domain-debug/
    ├── domain-refactor-safely/
    ├── domain-test-anti-patterns/
    ├── domain-test-effectiveness/
    ├── domain-review-requesting/
    ├── domain-review-receiving/
    ├── domain-git-worktrees/
    ├── meta-bootstrap/            #   meta (router, auto-injected)
    ├── meta-skill-writing/
    └── meta-patterns/
```

## Philosophy

- **Incremental progress over big bangs** — small changes that compile and pass tests
- **Test-driven when possible** — red, green, refactor
- **Evidence over assertions** — verify before claiming success
- **Persistent tracking** — bd issues survive across sessions
- **Explicit workflows over assumptions** — make the process visible

## Acknowledgments

Built on [obra/superpowers](https://github.com/obra/superpowers), [withzombies/hyperpowers](https://github.com/withzombies/hyperpowers), and [beads](https://github.com/steveyegge/beads).

## License

MIT
