# Bulk CSV Contact Upload

**Type:** User story / backlog item
**Priority:** Medium
**Status:** Backlog (not started)
**Captured:** 2026-05-15

## Story

**As a** field rep
**I want to** upload contacts in bulk via a CSV file
**So that** I don't have to spend evenings in the office typing entries one at a time.

## Context / problem

Field reps currently enter contacts one-by-one through the standard
contact form. After a day of meetings they come back with a stack of
business cards / lead lists and lose evening hours on manual data
entry. They've asked for a way to drop in a CSV and have the system
import the rows.

## Proposed scope (rough)

- Upload control on the contacts screen that accepts a `.csv` file.
- Server-side parse + validate rows before insert.
- Map common columns: name, company, email, phone, notes (column
  mapping UI is nice-to-have, not required for v1).
- Per-row error report so the rep knows which lines failed and why
  (bad email, duplicate, missing required field, etc.).
- Successful rows land in the rep's own contact list (same ownership
  rules as manually-created contacts).

## Acceptance criteria (draft)

- [ ] A field rep can select a CSV file from the contacts page and
      start an import.
- [ ] Valid rows are created as contacts owned by the uploading rep.
- [ ] Invalid rows are reported back with row number + reason; valid
      rows are not blocked by invalid ones (partial success is OK).
- [ ] Duplicate detection (by email) — duplicates are flagged, not
      silently overwritten.
- [ ] Reasonable file-size limit enforced (e.g. up to a few thousand
      rows) with a clear message above that.

## Open questions

- What's the canonical column set / required vs optional fields?
- Duplicate policy: skip, merge, or let the rep choose?
- Do we need a downloadable CSV template?
- Async (background job + notification) or synchronous on upload?
  Depends on expected row counts.

## Priority rationale

User flagged this as **medium-ish, not urgent**. It's a recurring
quality-of-life pain (evening hours lost) rather than a blocker, so
it belongs in the next-few-sprints bucket rather than the immediate
queue.
