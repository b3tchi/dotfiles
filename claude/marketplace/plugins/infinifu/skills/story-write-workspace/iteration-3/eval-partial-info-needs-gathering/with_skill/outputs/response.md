Using story-create skill to capture this as a user story.

Captured story **2605-001** (status: `draft`).

> As an **admin**, I want **to bulk-archive reports older than 90 days**, so that **stale reports are removed from active views and storage stays manageable**.

**Acceptance criteria** (derived — you didn't provide any, please confirm or revise):
- Admin can trigger a bulk-archive action that selects all reports with last-modified date older than 90 days
- A confirmation step shows the count of reports to be archived before the action proceeds
- Archived reports are moved out of active views but remain retrievable from an archive store
- Reports newer than 90 days are never included in the bulk-archive selection

**Tags chosen:** `[admin, reports]` (derived from the system area).

**Derivation flags:**
- `so_that` derived (you didn't state the motivation)
- `acceptance_criteria` derived (4 baseline bullets covering trigger, confirmation, archive behavior, boundary)
- `tags` derived

Storage: `product/stories.yaml`. Anything to revise?
