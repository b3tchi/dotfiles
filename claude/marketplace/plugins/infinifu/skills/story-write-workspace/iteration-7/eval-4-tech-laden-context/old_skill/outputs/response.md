Using story-write skill to capture this as a user story.

Wrote `/tmp/sw-iter7-eval4-old/docs/notes/us015.md` (status: draft).

**Connextra:** As a requestor, I want to export my request history as a CSV file, because accounting keeps asking for expense reports and screenshotting the dashboard is tedious.

**Acceptance criteria:**
- GET /api/requests/export returns a CSV response
- endpoint is served from the same auth-protected route as the dashboard (unauthenticated requests rejected)
- CSV contains one row per request
- each row includes the request date, status, and total line-item count

**Tags (H1):** `[[requestor-flow]]` `[[export]]` `[[product]]` — `requestor-flow` matches the existing tag taxonomy used on us013/us014; `export` is a new conceptual tag (may dangle, which is fine per the schema).

**Hub:** updated `docs/product.md` — added `[[us015|export request history as CSV]]` under `### [[pn001|requestor]]`.

**Stage on main:** skipped — sandbox is not a git repo, so `git add` is a no-op here. The file is on disk under the AKM root.

Note on tech stack (Next.js 14 / Postgres 16 / Drizzle ORM): not captured in the story — those are implementation concerns and will surface in the `im015` Implementation zettel and spec, not in the user story. The story stays at the requirement level (who, what, why).

Anything to revise?
