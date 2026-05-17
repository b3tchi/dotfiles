# Route decision

**From:** `infinifu:spec-writing` on `sp001`
**To:** `infinifu:idea-extend` on `us003`
**Reason:** `us003.acceptance_criteria` is vague ("it should work", "be fast enough"). `spec-writing` step 4 (AC check) blocks any solution proposal against shifting criteria.

## Next action for the user

1. Invoke `infinifu:idea-extend` on `us003`.
2. Refine `## acceptance_criteria` to concrete, testable items (numeric targets for rotation duration, overlap window, 5xx budget; rollback window; audit record). The spec's existing `## problem` prose already names good candidates — they need to move into the story AC.
3. Once AC are refined and `us003` status stays `ready`, re-run `infinifu:spec-writing` on `sp001`. The pre-gate checks (status `idea`, `## problem` populated, source story resolved) already pass — only step 4 was blocking.

## Why not `idea-implement`?

`idea-implement` mints a fresh `us###`. `us003` already exists and is captured. Adjusting AC on an existing story is the `idea-extend` entry-type per `infinifu:idea-brainstorming`.
