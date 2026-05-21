Using story-write skill to capture this as a user story.

Wrote **us015** to `/tmp/sw-iter7-eval4-new/docs/notes/us015.md`.

> As a **requestor**, I want **to export my request history as a CSV file**, because **accounting keeps asking me for expense reports and screenshotting the dashboard is tedious**.

**Acceptance criteria** (derived — see flag below):
- export produces one row per request in the requestor's history
- each row includes the request date, status, and total line-item count
- only the requestor's own requests appear in the export
- exporting with no request history produces a file with headers and no data rows

**Tags in H1:** `[[requestor-flow]]` `[[reporting]]` `[[product]]` — both flow/theme tags are suggester-derived (you didn't specify any).

**Hub:** updated `docs/product.md` under `### [[pn001|requestor]]`.

**Flags:**
- You didn't specify acceptance criteria, so I derived 4 from your context covering: row-level structure, required columns (the three fields you named), the auth boundary (only your own requests), and the empty-history edge case. Confirm or revise.
- I deliberately kept the AC problem-side — they describe what the requestor observes in the exported file, not the route name, HTTP verb, framework, or schema. The tech stack notes you gave (Next.js 14 / Postgres 16 / Drizzle, `GET /api/requests/export`, same auth-protected route as the dashboard) belong in the Implementation card (`im###`) and the spec, not the story. They'll be ready for `implementation-write` / `spec-writing` when this story flips to `ready`.

Anything to revise?
