# Operating modes

The `mode` configuration controls how the scrum master paces itself between batches.

## `auto` (default)

- Dispatches continuously — finish one batch, start next.
- Only stops for escalation-worthy events (see Escalation Protocol in SKILL.md).
- Reports progress after each batch but does not wait for human input.
- Best for: trusted plans where the human has already approved scope and just wants the pipeline to drain.

## `waves`

- Dispatches one batch, reports, waits for human feedback.
- Human can: approve next batch, adjust `max_parallel`, give guidance, stop.
- Best for: initial runs and tuning. Surfaces problems early before they propagate across the whole queue.

## `only-blockers`

- Like `auto` but halts on: agent failures, double rejections, blocked tasks.
- Does not halt between normal batches.
- Best for: semi-supervised runs — long queues where the human wants to step away but be paged on anything weird.

## Choosing a default

The skill itself does not pick a mode silently. If the user did not specify, ask. The dispatch summary should always echo the chosen mode so the human sees what they agreed to.
