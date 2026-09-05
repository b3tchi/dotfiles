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

## Pi Worker Orchestration (ft014)

Under Pi, infinifu runs its implementer/reviewer pipeline as **visible tmux
workers**: each worker is a Pi process in a named window inside your existing
linked project group, so you can watch it work and read its transcript. Claude
Code keeps its native `Agent` path and is unaffected.

    ./install.sh worker        # links the CLI + Pi extension
    infinifu-worker doctor     # checks nushell, tmux, XDG_RUNTIME_DIR, pi

### Authority boundaries

Four stores, one owner each. Nothing duplicates another's job:

| Owns | Store |
|---|---|
| Task state, dependencies, notes | `bd` |
| Source, branches, worktrees | Git |
| Knowledge artifacts | `akm` |
| Conversation history | Pi JSONL |
| Message transport (transient) | the bus, under `$XDG_RUNTIME_DIR` |

**tmux owns none of it.** It hosts and displays worker processes and nothing
more. No `send-keys`, no `wait-for`, no pane options, no `display-message` —
none of those can be versioned, sequenced, addressed, or replayed after a
crash, and `send-keys` types its text into whatever now occupies a stale
target. Messages travel only as versioned JSON envelopes under
`$XDG_RUNTIME_DIR/infinifu-worker/<run>/<worker>/`.

### Commands

    infinifu-worker spawn  --run <id> --uid <uid> --role impl --subject <t> \
                           --project <group> --repo <path> --session <sid> \
                           --skill work-do --task <bd-id>
    infinifu-worker send    <uid> --run <id> --stage work-do --task <bd-id>
    infinifu-worker wait    --run <id>          # oldest unacknowledged result
    infinifu-worker ack     --run <id> --uid <uid> --sequence <n>
    infinifu-worker status  <uid> --run <id>
    infinifu-worker inspect <uid> --run <id>
    infinifu-worker workers --run <id>          # whole run, from the bus alone
    infinifu-worker resume  <uid> --run <id> --feedback "<gaps>"
    infinifu-worker accept  <uid> --run <id> --repo <path>
    infinifu-worker stop    <uid> --run <id>

### Inspecting a running worker

Workers appear as `<role>-<subject>@<project>` in your window list, so
`impl-dotfiles-963w.4@dotfiles` is an implementer on that task. Switch to the
window and you are looking at the live session. A worker that crashes during
startup keeps its window (`remain-on-exit`), so its error stays on screen
instead of vanishing with the process.

`infinifu-worker workers --run <id>` reconstructs the whole run — every worker,
its state, its undelivered results, its resume command — from the bus alone.
Nothing about a run lives only in the orchestrator's conversation, so an
orchestrator that dies can be replaced by a new one.

### Delivery, acceptance, and cleanup

Three distinct things that are easy to conflate:

- **`wait` is not a subscription.** It reports the oldest unacknowledged result
  and leaves it in place, redelivering until you `ack`. An initiator that dies
  between reading a completion and acting on it sees the same completion again.
- **`ack` is a delivery receipt, not acceptance.** After `ack` the worker is
  still `complete`, its window is still open, and its worktree still exists —
  because a reviewer may still need to read them.
- **`accept` is what cleans up.** It closes the window and removes the
  worktree, and it refuses a worker that is not `complete`, one holding
  uncommitted work, or one with no identity on the bus. `stop` closes the
  window but *keeps* the worktree, since a stopped worker may hold unmerged
  commits.

Absent evidence is never permission: a worker with no identity reports
`unknown`, and `unknown` never licenses stopping, accepting, or deleting
anything.

### Resume

Every result carries the exact command that resumes its worker:

    pi --session <session-id>

The session id is stable and recorded before the process starts, so it survives
a crashed startup and outlives cleanup. Rejection uses it:
`infinifu-worker resume` sends reviewer feedback to the **original** session,
which still holds the context and the worktree, rather than dispatching a fresh
worker. A second rejection returns `escalate: true` and parks the worker at
`waiting_human` — at that point a person should look rather than a third retry
burning another turn on the same misunderstanding.

### Completion cannot be forged

A stage reports `complete` only with the verdict its own discipline produces,
read from the typed `validation` field and never from the summary —
`spec-refinement` must carry `SRE PASS`. An agent that ends its turn without
calling the result tool is recorded as `protocol_error`, never as success:
completion is never inferred from an idle prompt, an exited pane, or prose
claiming it.

### Tests

    nu tests/infinifu-worker/run-tests.nu

Runs schema, state-machine, static-boundary, bus, worktree, Pi-bridge,
pipeline, completion-safety, live-tmux and packaging suites, and exits nonzero
on any failure. Live tmux cases use private sockets (`tmux -L`), so they never
touch a real session.

### Live operator acceptance run

The automated suite exercises the bus, the stage gate, the window lifecycle and
the cleanup against a stub worker. It does **not** exercise Pi itself — the Pi
package is not a dependency of this repo, so Pi's event names, its
`sendUserMessage` signature and its agent-state vocabulary are carried from
[[ft014]] and have not been compiled against anything. The extension
feature-detects every host call and goes inert with a log line rather than
throwing, and unknown agent states defer rather than deliver, so a wrong
assumption costs a redelivery instead of a corrupted turn. Reconciling them is
this checklist's job. Run it once on a machine with Pi installed:

1. `infinifu-worker doctor` — every line `ok`, including `pi`.
2. `./install.sh worker`, then confirm Pi loads the extension (it must trust the
   project first). Look for infinifu's system-prompt block in a new session.
3. In a linked tmux project group, delegate a refinement:

       infinifu-worker spawn --run acc-1 --uid rev-sp028 --role rev \
         --subject sp028 --project <your-group> --repo <repo> \
         --session $(uuidgen) --skill spec-refinement
       infinifu-worker send rev-sp028 --run acc-1 --stage spec-refinement \
         --instructions "refine sp028" --artifacts sp028

4. Watch `rev-sp028@<group>` appear and the message arrive **as a user turn**.
   Record what Pi called the agent state while it was streaming — that is the
   value `decideDelivery` needs to match.
5. `infinifu-worker wait --run acc-1` returns a compact envelope carrying
   `SRE PASS`, while the window still shows the full reasoning.
6. `infinifu-worker resume rev-sp028 --run acc-1 --feedback "..."` reaches the
   **same** session (check the transcript continues rather than restarting).
7. `infinifu-worker accept rev-sp028 --run acc-1 --repo <repo>` closes the
   window and removes the worktree; `pi --session <id>` still resumes it.

Any mismatch in steps 2, 4 or 6 is an assumption to correct in
`extensions/pi.ts`, not a defect in the bus.

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
