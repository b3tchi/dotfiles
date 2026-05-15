Using story-find skill to surface stories touching this area + their validation state.

**Query:** "stories tagged requestor-flow"

**Tokens:** `["requestor-flow"]`

(Meta words `show`, `me`, `stories`, `tagged` dropped. The hyphenated `requestor-flow` is preserved as a single token because it appears hyphenated.)

Four stories tag-match `requestor-flow` (weight 5 each; tied on score, ordered by id ascending).

### us001 — order samples for upcoming client work   (match score: 5)

**As a** requestor (pn001), **I want** to order samples for upcoming client work, **because** I need product in hand for client tasting / presentation.

**Tags:** requestor-flow, catalog   **Status:** done

**Acceptance criteria:**
- [x] browse catalog of available samples
- [x] add items with quantity to a request
- [x] submit request to approver

Validated: 3/3 criteria met (status=done).

### us003 — track the status of my open requests   (match score: 5)

**As a** requestor (pn001), **I want** to see the status of every open request I submitted, **because** I want to know when I can pick up product without chasing the approver.

**Tags:** requestor-flow, tracking   **Status:** ready

**Acceptance criteria:**
- [ ] requestor dashboard lists every request the user submitted
- [ ] each row shows the current status (Submitted / Approved / Rejected / Completed)
- [ ] closed requests older than 30 days are hidden by default

Unverified: 0/3 criteria checked (status=ready).

### us013 — resubmit a Rejected or Blocked request after revising it   (match score: 5)

**As a** requestor (pn001), **I want** to resubmit a rejected or blocked request after revising the items, **because** recreating the whole request from scratch is wasteful when most line items were fine.

**Tags:** requestor-flow   **Status:** draft

**Acceptance criteria:**
- [ ] rejected request can be reopened from the rejected view
- [ ] previous line items pre-fill the new submission
- [ ] audit trail links the resubmission to the original

Unverified: 0/3 criteria checked (status=draft).

### us014 — bulk import requests from spreadsheet   (match score: 5)

**As a** requestor (pn001), **I want** to upload a spreadsheet to create many requests at once, **because** event prep means submitting dozens of similar requests and the per-row UI is slow.

**Tags:** requestor-flow, import   **Status:** draft

**Acceptance criteria:**
- [ ] accept .xlsx and .csv uploads
- [ ] each row maps to one request with line items
- [ ] preview parsed rows before commit and reject bad rows with row-level error messages

Unverified: 0/3 criteria checked (status=draft).

---

Coverage for "stories tagged requestor-flow": 4 matched stories — 1 done, 1 ready, 2 draft. Top match: us001 (score 5, tied with us003/us013/us014; ordered by id).
