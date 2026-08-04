---
name: agent-inbox
description: |
  A two-way message channel between running agents and the operator who owns the
  decisions. Both directions matter equally:

  Agent → operator: you hit a choice the task never specified (file format,
  schema, filename, library — anything unstated) while nobody is watching your
  output. Ask and park instead of picking a default.

  Operator → agent: send a message to an agent that is already working — redirect
  it, correct a wrong assumption, add a constraint, or tell it to stop — including
  agents that are NOT currently asking anything and have no pending question. Also
  covers seeing who is waiting, reading what is parked, and replying.

  Use for phrasings like: "make it ask me instead of guessing", "tell the running
  agent to drop X", "redirect the agent mid-task", "can I reach an agent that
  isn't asking anything", "how do I message a background agent", "who's waiting on
  me", "what is this old pending request", "answer the question it parked", or how
  agent-inbox / ask / park / resume / listen / tell / detached mode work.

  Not for: desktop notification hooks, email, Slack or --channels, listing or
  killing sessions, terminal permission dialogs, or note-taking inboxes.
---

# agent-inbox

An async question channel between a running agent and its operator. The agent
asks and parks; the operator answers by editing a file in a folder; the harness
wakes the agent when the answer lands.

**This skill is a how-to, not a trigger.** If you need agents to *reliably* ask
instead of guessing, run them under the `detached` agent (`claude --agent
detached`), whose system prompt makes it an unconditional rule. A skill loads
only when the model already suspects it is relevant — and an agent about to
silently pick JSON does not suspect anything. See `docs/notes/lab/poc021.md`.

## Agent side

Two verbs. Both are launched with the **Bash tool with `run_in_background` set to
`true`**, then you end your turn. Each parks with zero token cost and exits when
there is something for you; the harness re-invokes you on exit.

```bash
agent-inbox ask "<your question>" --timeout 43200   # ask, park, get the answer on stdout
agent-inbox listen                                  # park until the operator messages you
```

- **Never run either in the foreground.** The Bash tool's default timeout is
  120s and will kill the call mid-wait.
- **Never dispatch a subagent to run them.** Measured at ~15k tokens versus ~50
  for calling it yourself.
- `ask` is **idempotent**: re-asking the identical question resumes the existing
  request instead of creating a second one.
- On `TIMEOUT` (exit 2), run the same command again.
- The 12h default on `ask` is deliberate — the operator may be asleep. A short
  timeout turns one question into a stream of re-asks that answer nothing.

Multi-turn is just several `ask` calls: if a reply is a question rather than an
answer, answer it and ask again. **Never end your turn without either finishing
the work or having a pending `ask`/`listen`** — an agent with neither is
unreachable while appearing to work, and its empty inbox reads as "finished".

## Operator side

The interface is a directory; the commands are conveniences.

```bash
agent-inbox list                    # who is waiting, on what, in which project
agent-inbox reply                   # walk pending questions, answer inline
agent-inbox show <id>               # read one in full
agent-inbox edit [id]               # open in $EDITOR
agent-inbox answer <id> "<text>"    # non-interactive
agent-inbox tell <agent> "<text>"   # message an agent unprompted
agent-inbox path                    # where the store lives
```

Or skip all of it: `nvim $(agent-inbox path)`, type under `# reply`, save. The
file moves to `sent/` once the agent has read it.

## Request format

```markdown
---
from: webshop
subject: "Create checkout service config file"
project: "webshop"
created: 2026-08-03 08:21:53
---

# question
...

# reply
<your answer here>
```

`subject` and `project` are derived (git root basename; `AGENT_PROJECT`
overrides), not supplied by the agent — so one store can serve many agents
across many repos.

## Store

`$AGENT_INBOX`, else `$XDG_STATE_HOME/agent-inbox`, else
`~/.local/state/agent-inbox`. Mode 0700; answered exchanges are archived under
`sent/` and pruned after `$AGENT_INBOX_MAX_AGE` (default 14 days).

## Known gaps

- **Permission prompts are not routed here.** A prompt *awaiting* an answer
  still traps an unattended agent — no instruction can redirect it, because the
  harness raises it, not the agent. A *denied* one does come back through the
  inbox.
- **No notification.** You discover a request by looking. A real run went ~9
  hours unseen.
- **Deliberate reminders mint a new request** rather than updating the existing
  one.

Evidence: `docs/notes/lab/poc020.md` (channel), `poc021.md` (mode), `docs/notes/spec/sp025.md`.
