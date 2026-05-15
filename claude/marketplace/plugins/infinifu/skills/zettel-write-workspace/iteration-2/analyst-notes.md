# Iteration 2 — analyst observations

## Aggregate

| Metric | iter1 with-skill | iter1 baseline | iter2 with-skill | iter2 baseline |
|--------|------------------|----------------|------------------|----------------|
| Pass rate | 28/28 (100%) | 18/28 (64.3%) | 36/36 (100%) | 31/36 (86.1%) |
| Time mean | 96s | 41s | 86s | 45s |
| Tokens mean | 45k | 27k | 49k | 31k |

Iter2 delta dropped from +34pp to +16pp — but **the change is mostly noise from baseline contamination on eval-3**, not a skill regression. With-skill stays at 100% across both iterations and now correctly handles the new hidden-compound eval (eval-4).

## Per-eval discrimination — iter2

| Eval | with-skill | baseline | Δ | Pattern |
|------|------------|----------|---|---------|
| 1 atomic-single-concept | 10/10 | 10/10 | 0 | Still non-discriminating. Vault prior-art carries baseline. Both iterations match. |
| 2 compound-split-prompt | 8/8 | 7/8 | +1 | Stable — single assertion gap on "principle visibility". Baseline splits but admits no principle applied. |
| 3 route-to-story-write | 10/10 | 10/10 | 0 | **CONTAMINATED in iter2.** Baseline agent autonomously discovered `akm.md` in the sandbox (not listed in its prompt's read-only manifest) and followed the Story schema. Iter1 baseline scored 1/10. Difference is agent curiosity, not skill design. |
| 4 hidden-compound-comparison (NEW) | 8/8 | 4/8 | +4 | Clean discrimination. Skill caught the hidden compound ("X — how it differs from Y") and split into 2 cards. Baseline wrote 1 card with `## vs pessimistic locking` H2 inside — exactly the failure mode the skill was designed to prevent. Δ comes from: split detection (1), 2 files (1), no compound H2 (1), mutual links (1). |

## Skill improvements that landed

Three changes shipped in iter2 SKILL.md:

1. **Hidden-compound patterns** (`Step 1`): added explicit examples (`X — how it differs from Y`, contrasts, parenthetical clauses). Iter2 eval-4 with-skill cited this pattern by name in its summary.
2. **H1 tag fabrication guard** (`Step 2`): "never fabricate a tag wikilink just because the schema allows it". Iter2 eval-3 with-skill explicitly cited the rule ("skill forbids fabricating") when deciding to omit flow/theme tags.
3. **Subagent output_files declaration** — punted to next iteration; the harness-blocks-Write-on-report-files issue is a sandbox quirk, not a skill defect. Real-world Claude sessions don't hit it.

Both shipped changes produced visible behavior in the iter2 runs. The skill's discipline is now durably visible in summaries (not just an implicit pattern).

## Baseline contamination on eval-3

What happened: iter2 eval-3 baseline agent listed the sandbox `docs/notes/` directory, noticed `akm.md`, read it, and followed the Story schema exactly. Iter1 baseline didn't do this — it ignored the dir contents not explicitly named in the prompt's manifest.

Why it matters: eval-3 was the strongest discriminator in iter1 (+9 assertions). Iter2 baseline got to 10/10 by reading documentation. The skill's real value on eval-3 is still real — it's about *consistency* and *not having to discover the schema*, not about whether the schema is reachable.

Fix for iter3 (if rerun): either
- Strip `akm.md` from baseline sandbox (true no-AKM-context test), OR
- Add `akm.md` to baseline's listed manifest (consistent visibility — baseline still has to interpret + apply correctly, but discovery isn't the variable).

The second is cleaner — tests skill-as-application-discipline rather than skill-as-knowledge-injection.

## Cost — iter2

With-skill: 86s mean, 49k tokens. Baseline: 45s, 31k. Skill premium ~92% time, ~57% tokens — same shape as iter1.

## Decision

zettel-write v2 (iter2) is ready to ship. Discriminates strongly on hidden-compound (the case the skill is principally designed to catch), holds 100% across all 4 evals, and the improvements landed in observable behavior. Eval-1 stays as a non-regression sentinel, eval-3 baseline contamination is documented but doesn't invalidate the skill's real value.

Two follow-up items (not blocking):
- Fix eval-3 baseline visibility (iter3 if rerun)
- Build the AKM micro-skills (`adr-write`, `feature-write`, etc.) — bd `dotfiles-4by`
