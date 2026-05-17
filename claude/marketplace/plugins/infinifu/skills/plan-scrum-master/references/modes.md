# Operating modes

The `mode` configuration controls how the scrum master paces itself between batches.

## `only-blockers` (default)

- Like `auto` but halts on: agent failures, double rejections, blocked tasks.
- Does not halt between normal batches.
- Best for: semi-supervised runs — long queues where the human wants to step away but be paged on anything weird. This is the sane default: combine with `worker_model=sonnet` and the failure-escalation rule, and most queues drain without intervention while real problems still surface fast.

## `auto`

- Dispatches continuously — finish one batch, start next.
- Stops only for escalation-worthy events (see Escalation Protocol in SKILL.md).
- Reports progress after each batch but does not wait for human input.
- Best for: trusted plans where the human has already approved scope and just wants the pipeline to drain even on hard failures (rare — `only-blockers` is usually safer).

## `waves`

- Dispatches one batch, reports, waits for human feedback.
- Human can: approve next batch, adjust `max_parallel`, give guidance, stop.
- Best for: initial runs and tuning. Surfaces problems early before they propagate across the whole queue.

## Choosing a mode

The default is `only-blockers`. If the user did not specify, offer the default but ask before assuming — wave-mode in particular is worth flagging on first runs. The dispatch summary should always echo the chosen mode so the human sees what they agreed to.
