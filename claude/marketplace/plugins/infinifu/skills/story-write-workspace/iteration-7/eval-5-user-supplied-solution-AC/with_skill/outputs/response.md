Using story-write skill to capture this as a user story.

## Story created: us015

**File:** `/tmp/sw-iter7-eval5-new/docs/notes/us015.md`

**Connextra:** As a `requestor`, I want `attach a PDF receipt to a request`, because `the approver has documentation`.

**Acceptance criteria** (preserved verbatim from your input):

1. Add a 'Attach receipt' button to the request form
2. POST /api/requests/{id}/attachments accepts multipart/form-data and returns 201
3. Store the file in S3 under requests/{id}/{uuid}.pdf
4. Add an attachments column to the requests table linking to attachment ids

**H1 tags:** none — just `[[product]]`. You didn't specify tags and I didn't run the suggester (the story is small and the persona grouping in the hub is enough). Say the word if you want `tag-manage` to propose flow/theme tags.

**Hub:** `docs/product.md` updated — `[[us015|attach a PDF receipt to a request]]` appended under `### [[pn001|requestor]]`.

**Staged on main** (not committed — `draft` artifact; `spec-writing` will commit on `draft → ready`).

---

## Flags — solution-shaped acceptance criteria

All four AC you supplied read as **solution-side** rather than problem-side. I wrote them verbatim because you may be constrained by an existing contract I can't see, but flagging each one so you can decide:

> *"AC #1 reads as a solution (`Add a 'Attach receipt' button to the request form` — names a UI element). Spec-writing decides HOW; want me to rephrase as observable behavior (e.g. 'requestor can upload a receipt PDF from the request form'), or keep as-is?"*

> *"AC #2 reads as a solution (`POST /api/requests/{id}/attachments accepts multipart/form-data and returns 201` — pre-commits a REST contract: route, verb, content-type, status code). Spec-writing decides HOW; want me to rephrase as observable behavior (e.g. 'uploading a receipt succeeds for a valid PDF and the request now shows it attached'), or keep as-is?"*

> *"AC #3 reads as a solution (`Store the file in S3 under requests/{id}/{uuid}.pdf` — pre-commits storage backend, path layout, and file extension). Spec-writing decides HOW; want me to rephrase as observable behavior (e.g. 'an uploaded receipt is durably stored and retrievable by the approver'), or keep as-is?"*

> *"AC #4 reads as a solution (`Add an attachments column to the requests table linking to attachment ids` — pre-commits the database schema). Spec-writing decides HOW; want me to rephrase as observable behavior (e.g. 'a request can carry one or more receipts and each receipt is reachable from the request'), or keep as-is?"*

Why this matters: AC are the *problem* sharpened, not the *plan*. Pre-committed solutions in AC lock the design before `spec-writing` weighs alternatives (S3 vs filesystem vs DB blob, REST vs presigned upload, multi-attachment vs single, etc.). If these are hard external constraints, say so and they stay; if they're just how you happened to phrase the requirement, I'll reword in place.

**Anything to revise?**
