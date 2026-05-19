# Iteration 1 — analyst observations

## Per-eval discrimination

| Eval | with_skill | without_skill | Δ | Pattern |
|------|------------|---------------|---|---------|
| 1 atomic-single-concept | 10/10 (100%) | 10/10 (100%) | 0 | Non-discriminating. Baseline matched the format by mimicking the in-vault style (circuit-breaker.md, on-call-rotation.md). Easy case. |
| 2 compound-split-prompt | 8/8 (100%) | 7/8 (88%) | +1 | Baseline split correctly but admitted in summary that split was inferred from vault style, NOT from any explicit atomicity rule. With-skill cites the skill's atomicity gate by name and runs Steps 1-4 audit. Single-assertion difference. |
| 3 route-to-story-write | 10/10 (100%) | 1/10 (10%) | +9 | Baseline wrote a generic backlog file (`# Bulk CSV Contact Upload`, no [[product]], no Index footer, no us### id, no AKM schema). With-skill correctly detected story shape and followed AKM Story schema exactly. Decisive win — AKM knowledge isn't derivable from sandbox examples alone. |

## Cost

- Time: +135% (96s vs 41s mean) — skill reading + audit steps add ~50s
- Tokens: +66% (45k vs 27k) — skill content + decision-log overhead

## Non-discriminating eval (eval-1)

Both configs landed 10/10 because the vault had two example zettels in the right shape. The skill's value is *invisible* on a vault with strong prior art. Two options for iteration 2:

1. Add an empty-vault eval — request a concept zettel with NO existing zettels except `product.md` and `akm.md` — baseline will likely improvise some non-AKM format.
2. Accept eval-1 as a "skill doesn't hurt easy cases" sentinel; replace with a harder atomicity case (e.g. user supplies a prompt that LOOKS atomic but is actually two ideas hiding in nuance).

## Surprises

- **Both configs split eval-2.** Compound prompt was syntactically obvious ("X, and Y"); even Claude without the skill split it. Eval-2 may be too easy — design a subtler compound case for iteration 2 (e.g. two ideas implicit, not joined by "and").
- **Harness blocked summary.md writes for 3 of 6 agents.** Bash heredoc worked as fallback; agents that didn't fall back returned inline summaries via task notification. Not a skill defect; documenting for grading.

## Suggested skill changes for iteration 2

1. Tighten the atomicity-gate examples — add a case where "and" is absent but the request is still compound (eg. *"a CRDT — and how it differs from OT"* hides the second idea in "differs from"). Right now the skill emphasises explicit conjunctions.
2. The "summary harness blocked" pattern shows agents weren't sure they had permission to write report files. Consider a `output_files` listing inside the workflow that pre-declares which paths the skill writes to.
3. Eval-3 with-skill skipped optional H1 tags (`[[<flow-or-area>]] [[<theme>]]`) — declined to fabricate dangling tags. That's the right call but the skill doesn't currently explain *when* H1 tags are appropriate vs when to skip. Add guidance.

## Decision

Skill works for the cases tested. Real gain is in eval-3 (AKM schema compliance — +9 assertions). Eval-2 modest. Eval-1 cosmetic. Move to user review.
