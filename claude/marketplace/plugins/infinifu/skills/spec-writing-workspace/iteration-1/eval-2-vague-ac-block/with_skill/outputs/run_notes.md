# Run notes — eval-2 vague-AC-block (with_skill)

## Task

Run `infinifu:spec-writing` on `sp001`. `sp001.status = idea`, `## problem` populated. Source story `us003.acceptance_criteria` is intentionally vague. Skill's step-4 AC gate must fire and block.

## AC assessment

`us003.acceptance_criteria`:

```
- it should work
- be fast enough
```

Both items fail the AC gate from `spec-writing` step 4 / Disambiguation rule
("Source `us###.acceptance_criteria` is empty / vague → block; route back to
`idea-implement` (or `idea-extend`)") and from `akm.md` Process Flow step 2
("If anything is vague, refine before moving on — no point in implementing
against a moving target"):

- "it should work" — no observable behavior, no contract. Untestable.
- "be fast enough" — no numeric target, no percentile, no measurement window. Untestable.

`sp001.problem` *does* name plausible targets (5-minute overlap, zero 5xx), but those live in the spec prose, not the story AC. Per Key Principles ("AC bind the solution"), the spec cannot tighten what the story left vague — that would invert ownership (story is the contract; spec executes it).

## Block decision

**Blocked at step 4. Did NOT write `## solution`. Did NOT flip status. Did NOT touch `docs/board.md`.**

Routed to `infinifu:idea-extend` on `us003` (existing story → extend, not implement-new). Suggested concrete AC candidates derived from `sp001.problem` prose, listed in `gate_reached.md` for the user to confirm/refine in the next skill.

## Why `idea-extend` over `idea-implement`

`us003` already exists at `status: ready`. `idea-implement` mints fresh stories; `idea-extend` adjusts existing stories. The eval prompt explicitly named both as valid routes — picked `idea-extend` for accuracy.

## Sandbox changes (staged, NOT committed)

- `gate_reached.md` (new) — full block report: pre-gate checks passed, step-4 evidence, route decision, what was deliberately NOT done.
- `route_decision.md` (new) — short route summary for tooling/automation.
- `.seed_manifest.txt` was already present in the seed; got staged by `git add -A`.

No AKM file (spec, board, story, product) was modified. The skill's promise that "the solution must already exist at `status: idea`" + the AC gate held — block fired cleanly before any write.

## Skill behavior assessment

Positive:
- Step 4 of the entry-specific checklist is unambiguous; the rule fired without interpretation gymnastics.
- Disambiguation block lists this exact scenario verbatim, so the routing decision was deterministic.
- Key Principles ("AC bind the solution") reinforces the gate at the policy level, not just the procedural level — useful when the procedural rule is tempting to skip ("but the problem section already names targets!").

Tension noted:
- `sp001.problem` carrying concrete targets while `us003.AC` stays vague is a realistic anti-pattern (people often write the good detail at the spec stage instead of correcting the story). The skill correctly refuses the easy out of "promote prose to AC inline" — that would conflate stages. Worth keeping.
