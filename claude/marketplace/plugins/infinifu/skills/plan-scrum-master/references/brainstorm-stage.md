# The brainstorm stage instruction

sp029's whole reason to exist: an agent spawned to converse with a human, that
decides for itself when the conversation is finished, and reports back so the
agent that started it can proceed — with nobody relaying anything by hand.
There is no registry entry for this any more ([[ft013]]/sp029 T8 retired the
stage registry outright): "the brainstorm stage" is this instruction, sent
verbatim as the spawned agent's first message, plus `spawn --isolation main`.
Nothing else configures it.

## Why the instruction is copied here in full, not linked

[[sp025]]'s [[poc021]] measured the failure mode this instruction exists to
avoid: soft guidance is **inert**. A rule living in `CLAUDE.md` or passed via
`--append-system-prompt` produced answers statistically identical to a
no-instruction control — while the agent could still recite the rule
perfectly when asked. Knowing a rule and being governed by it are different
things, and the difference only showed up in *behavior*, never in
self-report.

So this text is not a link, a skill name, or a footnote the agent is expected
to go look up. `send --content` carries it whole, as the actual first thing
the brainstorm agent reads — live context, not background configuration. A
dispatcher that instead sends `"see brainstorm-stage.md"` has reintroduced
the soft-guidance shape the PoC already falsified.

## The instruction (send this verbatim via `send --content`)

```
You are running a brainstorm stage. A human is at this window's other end —
not on the message bus, not reachable by any other agent, only here. Talk
with them until the two of you have actually reached a decision, or until you
are certain no decision is coming.

You decide when this conversation is finished. Not the human saying a
magic word, not a message count, not a timer — your own judgment that the
question has been answered or that it plainly will not be. When you decide,
report a typed result and stop — it is addressed automatically to whoever
commissioned you, so you never need to name them yourself:

    pi-worker result --as <your-uid> --status <status> --summary "<summary>" [--validation "<validation>"]

`--status` is one of:
  - complete       — you and the human reached an explicit decision. --validation
                      is REQUIRED and must name what makes you sure it is a
                      decision and not your own preference (a direct quote or
                      an explicit yes, never "seemed reasonable").
  - waiting_human  — still needs the human: they have gone quiet, or a
                      question is still open. This is what "waiting_human"
                      has always meant here: a human is needed AT THIS WINDOW,
                      never that mail is waiting for someone on the bus.
  - blocked        — the conversation reached a real obstacle that is not a
                      human-input gap (contradictory constraints, a decision
                      that needs someone else entirely).
  - failed         — the conversation cannot produce what it was commissioned
                      for.

Never report `complete` to look finished. If the conversation is
inconclusive, ambiguous, or the human never confirmed anything, that is
`waiting_human` or `blocked` with an honest summary of where it stands — NOT
`complete` with a summary that papers over the gap. A short, honest
`waiting_human` is correct output; a fabricated `complete` is not, no matter
how long you have been at this.

You may NOT decide these on your own — each needs an explicit, stated answer
from the human before you may treat it as settled. Absence of a stated
preference is not permission to pick a default and move on:

  1. Whether the design or approach is APPROVED enough to report `complete`.
     Your own recommendation is not an approval. Only the human's explicit
     agreement is.
  2. Any file format, schema/data shape, library, dependency, or naming
     choice the human has not stated. Silence on one of these is not a
     decision — surface it and ask, or report the conversation as still open.
  3. Scope boundaries: what is in and what is out of what gets built next.
     Confirm explicitly; never infer from what the human didn't object to.
  4. Anything with an effect outside this conversation: writing a file,
     creating a ticket, running a command, spawning another agent. Never do
     any of this during a brainstorm — that is a later stage's job, and you
     report a decision for that stage to act on, not act on it yourself.

If the human stops responding, wait. Do not fill the silence by inventing
what they would probably have said. A commissioner asking you for a status
mid-conversation gets `waiting_human` and an honest one-line account of where
the conversation paused — never a summary that pretends the human weighed in
on a point they never touched.
```

## What the orchestrating skill does with a finished brainstorm

This is the other half of the motivating case — reading the result and
proceeding, with nobody relaying anything by hand. Whoever ran `spawn`
already has the address the result comes back to: it is the `run` field
`spawn`'s own JSON reply carried, captured at spawn time (see
`plan-scrum-master/SKILL.md`'s Pi worker pipeline table — `$RUN` there, not a
stable identity of its own).

```
pi-worker wait --as $RUN --block --timeout 60
```

While the human and the brainstorm agent are still talking, this call returns
nothing — repeatedly, for as long as the conversation runs. That is the
correct behavior, not a stall: a `wait` that returns empty costs nothing to
repeat, and the alternative (polling a transcript, or asking the human "is it
done yet") is exactly the relay this bus exists to remove.

Once the brainstorm agent calls `result`, the next `wait` returns it as an
ordinary addressed message: `content.status`, `content.summary`, and
`content.validation` when `status` is `complete`. The orchestrating skill
acts on those typed fields directly —

- `complete` — proceed to the next stage using `content.summary` as the
  decision; do not re-derive it from the transcript, and do not ask the human
  to repeat what they already told the brainstorm agent.
- `waiting_human` — nothing to do yet; the human is still needed at that
  window. Poll again later, or surface the wait to whoever is tracking the
  larger flow.
- `blocked` / `failed` — report onward with `content.summary` as the reason;
  do not retry the same brainstorm expecting a different outcome without
  new input.

No status is ever inferred from the worker's window going idle, from its
pane exiting, or from prose in a message — only from these typed fields
([[adr0027]]).

## Two brainstorm agents mentioned in one message

`send --to` accepts a list, so one message can name two brainstorm agents at
once (e.g. relaying the same clarifying context to both) and both wake —
nothing in the transport serializes them (sp029's "everyone reacts at once").
Each still decides and reports independently, to ITS OWN commissioner: since
each was brought up by its own `spawn` call, each has its own `run`, and
each's `result` lands on that run's queue and no other. The orchestrating
skill does not get to `wait` once and receive both answers — it tracks one
`$RUN` per brainstorm it commissioned (however many spawns it made) and
calls `wait --as` on each in turn. Naming two agents in one outbound message
is not the same as the two sharing one conversation or one report-back
address; it only shares the one message being relayed to both.
