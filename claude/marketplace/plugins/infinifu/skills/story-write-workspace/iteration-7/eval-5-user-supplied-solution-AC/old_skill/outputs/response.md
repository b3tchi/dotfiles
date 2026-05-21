Using story-write skill to capture this as a user story.

Story written: `us015` at `/tmp/sw-iter7-eval5-old/docs/notes/us015.md`.

**Connextra:** As a requestor, I want to attach a PDF receipt to a request, because the approver has documentation to support the request.

**Acceptance criteria (verbatim from user):**
- Add a 'Attach receipt' button to the request form
- POST /api/requests/{id}/attachments accepts multipart/form-data and returns 201
- Store the file in S3 under requests/{id}/{uuid}.pdf
- Add an attachments column to the requests table linking to attachment ids

**H1 tags:** `[[requestor-flow]] [[attachments]] [[product]]` — `requestor-flow` follows existing convention from us013/us014; `attachments` is a new theme tag derived from the story topic. Both are agent-suggested (user did not specify tags).

**Hub updated:** `docs/product.md` — appended `[[us015|attach a PDF receipt to a request]]` under `### [[pn001|requestor]]`.

**Status:** `draft`. Sandbox is not a git repo, so no staging performed.

Anything to revise?
