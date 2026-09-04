# Runtime Adapter Contract

This is the shared adapter reference for Infinifu lifecycle skills. Cite this
file when a skill needs runtime-specific behavior instead of restating the full
rule in each skill.

## Runtime selection

Runtime selection is explicit and ordered:

1. `AI_AGENT=pi` selects the Pi adapter.
2. When `AI_AGENT` is unset and Claude's native Agent / Task tool surface is
   available, select the Claude-native adapter and preserve the existing Claude
   behavior.
3. Any runtime with no Pi marker and no Claude native surface must fail closed
   with an `unsupported-runtime` error. Do not silently fall through to a
   partial adapter.

A later adapter can add a new branch here without changing the lifecycle state
model. The state model remains runtime-neutral.

## Control channel and durable state

Direct messaging remains the primary control channel. Runtime adapters may
choose different transports for that channel, but tmux is only a visible process
host unless an adapter explicitly documents a stronger messaging contract.

Durable state remains in `akm`, `bd`, and Git; adapters do not replace those
stores:

- `akm` owns AKM reads and writes.
- `bd` owns task state, dependencies, notes, and discovered work.
- Git owns source branches, commits, worktrees, and merge state.

Do not store durable lifecycle state in runtime-only process metadata.

## Adapter outcomes

### Pi: `AI_AGENT=pi`

Pi does not include Claude Agent / Task subagents. Skills running in Pi must not
simulate those subagents, claim they were dispatched, or infer completion from a
tmux pane. Sequential execution is valid. Multi-worker behavior requires a Pi
runtime adapter such as [[ft014]]; until it exists for the requested operation,
report the operation as unsupported rather than pretending the Claude surface is
available.

### Claude native surface

When Claude's native Agent / Task tools are available, keep the existing Claude
behavior: dispatch through the native tool surface, use its supported messaging
and resume semantics, and preserve the existing lifecycle gates.

### Unsupported runtime

If neither `AI_AGENT=pi` nor Claude's native surface is available, stop with an
`unsupported-runtime` failure. The failure should name the missing runtime
surface and the lifecycle operation that cannot proceed.

## Completion envelope

Delegated stages cannot report completion before their required validation passes.
A compact return must include:

- result
- validation verdict or command evidence
- visible worker name
- exact resume command

If validation fails or cannot run, the delegated stage returns blocked or
failed, not complete.
