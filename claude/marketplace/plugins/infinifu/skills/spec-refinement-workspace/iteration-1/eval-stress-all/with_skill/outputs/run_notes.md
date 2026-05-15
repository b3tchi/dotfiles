# Run notes — spec-refinement eval (stress-all, with_skill)

Applied the full 8-category checklist from `infinifu:spec-refinement/SKILL.md` to each of the four seeded tasks under epic `eval-upg`.

## Changes by task

- **eval-ksj (Task A, VIN scanner)** — Driven by Category 7 (placeholder text `[Complete implementation steps detailed above]`, `[As specified in the implementation checklist]`), Category 3 (vague criteria), Category 6 (no edge cases), Category 8 (no checksum requirement → tests were meaningless). `bd update --design`: concrete ISO 3779 checksum algorithm, bounded regex (no backtracking), 8 named behavior tests, Unicode byte-offset handling, strengthened anti-patterns.

- **eval-z2i (Task B, license-plate family)** — Driven by Category 1 (~40h exceeds 16h ceiling, auto-reject), Category 2 (one-liner checklist), Category 3 ("works across all 50 states" unverifiable), Category 5/6 (no false-positive strategy, no context detection spec). Decomposed into 5 child subtasks via `bd create --parent eval-z2i`: eval-z2i.1 (catalog + tier-1 regex, 7h), .2 (generic fallback + 40 states, 5h), .3 (healthcare context + dictionary suppression, 6h), .4 (confidence scoring + config, 5h), .5 (benchmark + integration, 5h). Sequential blocking deps added via `bd dep add`. Parent updated to coordinator with release-gate precision/recall criteria.

- **eval-sm2 (Task C, encryption at rest)** — Driven by Category 5 (no mode specified → ECB would satisfy literal spec), Category 8 (`test_encrypts_file_exists` tautological — `memcpy` would pass), Category 6 (no tamper/wrong-key/concurrency/KMS-failure coverage), Category 4 (missing dependency on Task D's model). `bd update --design`: AES-256-GCM with per-document CEK wrapped by KMS KEK, unique-nonce and unique-CEK uniqueness tests across 10_000 samples, tamper/wrong-key/blob-version/empty/Unicode/concurrent tests, storage-layer plaintext-leakage integration test, key zeroization, and forbidden-mode anti-patterns. Added `bd dep add eval-sm2 eval-3ka`.

- **eval-3ka (Task D, ScanResult model)** — Driven by Category 8 alone: all four original tests (`has_scanner_id_field`, `has_match_count_field`, `can_be_constructed`, `derives_debug`) are compiler-checked tautologies. `bd update --design`: replaced with 10 behavior tests (timestamp freshness, match_count semantics, validator rejects inverted/zero span, confidence range, snippet-span length consistency, empty scanner_id, empty matches accepted, serde round-trip incl. Unicode + `deny_unknown_fields`, deep-clone independence). Added `validate()` semantics, forbade derived `Default`, forbade logging snippets at INFO+.

## Artifacts

- `review_summary.md` at sandbox root — per-task verdict + one-paragraph reasoning.
- 5 new bd issues: eval-z2i.1, eval-z2i.2, eval-z2i.3, eval-z2i.4, eval-z2i.5.
- 5 new dependency edges: .2→.1, .3→.2, .4→.3, .5→.4, eval-sm2→eval-3ka.
- No tasks closed; no `bd commit`/`bd merge`; no `.beads/` git-add.

Post-review final tree has 10 open issues (original 5 + 5 new subtasks).
