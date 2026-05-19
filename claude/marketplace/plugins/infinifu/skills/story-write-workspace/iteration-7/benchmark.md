# story-write — iteration-7 benchmark

Iteration adds "problem-side, not solution-side" discipline to acceptance criteria
authoring. Baseline = current SKILL.md prior to this iteration's edit.

## Summary

| eval | with_skill | old_skill | delta |
|---|---|---|---|
| 4 tech-laden-context-derives-problem-side-AC | 10/10 (100%) | 8/10 (80%) | +20pp |
| 5 user-supplied-solution-AC-flags-leakage   | 9/9 (100%)  | 7/9 (78%)  | +22pp |
| 6 solution-shaped-want-pushback              | 7/7 (100%)  | 4/7 (57%)  | +43pp |
| **TOTAL**                                    | 26/26 (100%) | 19/26 (73%) | +27pp |

## Key behavioral deltas

### eval-4 (tech-laden context, no explicit AC supplied)

User dumps tech stack (Next.js, Postgres, Drizzle, `GET /api/requests/export`).
New skill must derive AC in problem-space, not echo the user's tech vocabulary.

- **with_skill:** AC bullets describe outcomes — "export produces one row per
  request", "only the requestor's own requests appear", "exporting with no
  history produces a file with headers". Zero tech leakage.
- **old_skill:** AC #1 = "GET /api/requests/export returns a CSV response";
  AC #2 = "endpoint is served from the same auth-protected route as the
  dashboard". Implementation contract leaks straight into the story.

### eval-5 (user supplies solution-shaped AC verbatim)

User writes AC as developer tasks: "Add button", "POST endpoint returns 201",
"Store file in S3 under requests/{id}/{uuid}.pdf", "Add attachments column".

Both versions correctly **preserve user's wording in the file** (the rule
forbids silent rewriting). Differentiator is the **confirmation step**:

- **with_skill:** flags every solution-leaking bullet inline, suggests a
  problem-side reframe per bullet, asks user whether to rephrase or keep.
  Explains the "spec-writing decides HOW" reason.
- **old_skill:** straight transcription, no flag, no comment. User has no
  signal that the AC may pre-commit the design.

### eval-6 (user's `want` is solution-shaped — names a UI element)

User: "I want a 'Cancel' button on the request detail view."

- **with_skill:** pushes back once with an outcome-shaped alternative ("cancel
  a request I've already submitted, because I sometimes change my mind"),
  preserves user wording on decline, AND keeps derived AC strictly
  problem-side ("requestor can cancel", "cancellation only possible while...",
  "cancelled request visibly marked"). UI element does not propagate.
- **old_skill:** accepts the want verbatim AND derives AC that all reference
  "Cancel button" by name — UI prescription cascades through every bullet.

## Cost

| eval | with_skill tokens | old_skill tokens | with_skill ms | old_skill ms |
|---|---|---|---|---|
| 4 | 53221 | 51665 | 80643 | 72805 |
| 5 | 53408 | 50708 | 82860 | 60143 |
| 6 | 52340 | 50273 | 68057 | 71625 |
| avg | 52990 | 50882 | 77187 | 68191 |

With-skill costs ~4% more tokens and ~13% more wall-clock — the extra context
is the problem-side discipline + flag-generation, not extra tool calls.
