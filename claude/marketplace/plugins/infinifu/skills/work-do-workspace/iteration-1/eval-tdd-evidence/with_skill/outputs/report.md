Task eval-3nh: Implement slug generator — ready for review

Summary: Implemented `slugify(title: str) -> str` in `src/slugs.py` via strict TDD (RED -> GREEN): wrote `tests/test_slugs.py` first, captured the import-error RED, then added a pure-Python implementation that lowercases, collapses whitespace runs into a single hyphen, drops any character outside `[a-z0-9-]`, and strips leading/trailing hyphens. 6/6 tests green.

Files changed:
- `src/slugs.py` (new, 34 lines)
- `tests/test_slugs.py` (new, 33 lines)

Tests: 6 added, 0 modified, all green (`python3 -m pytest tests/test_slugs.py -v` -> `6 passed in 0.01s`).

Deviations: none.

Discoveries filed: none. Unicode / non-ASCII handling is explicitly out of scope per the task; the `[a-z0-9-]` filter silently drops non-ASCII bytes along with any other disallowed char. No unicode requirement surfaced during implementation.

Task status: `in_progress` (left open for reviewer per work-do Step 7 — reviewer owns the `in_progress -> closed` transition). Implementation evidence recorded in the task's Notes field via `bd update eval-3nh --notes "IMPLEMENTED: ..."`.

Commit: `c5161e2 feat(slugs): implement slugify per bd task eval-3nh` on branch `master`.
