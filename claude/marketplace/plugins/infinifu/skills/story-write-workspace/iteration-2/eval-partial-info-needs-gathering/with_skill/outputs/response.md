Using story-create skill to capture this as a user story.

**Story id:** `2605-001`
**Status:** `draft`
**Storage:** `product/stories.yaml`

**Connextra form:**
> As an admin, I want to bulk-archive reports older than 90 days, so that stale reports are removed from active views and storage stays manageable.

**Acceptance criteria:**
- Admin can select or trigger archival of all reports with a created/modified date older than 90 days in a single action
- Reports younger than 90 days are never included in the bulk-archive selection
- Archived reports are moved out of active views but remain retrievable from an archive store
- A confirmation summary shows the count of reports archived and any failures before completion

**Heads up — derivation flag:** You did not provide acceptance criteria or an explicit `so_that`. I derived the `so_that` ("stale reports removed... storage stays manageable") and all 4 acceptance criteria from the want phrase, covering: entry point (single bulk action), boundary (the 90-day cutoff), success path (archive store retrievability), and reporting/error case (confirmation summary). The only field that came directly from you is the role (`admin`) and the core want (bulk-archive reports >90 days old). Please confirm or revise — particularly the `so_that` and any criterion that doesn't match your intent.

Anything to revise?
