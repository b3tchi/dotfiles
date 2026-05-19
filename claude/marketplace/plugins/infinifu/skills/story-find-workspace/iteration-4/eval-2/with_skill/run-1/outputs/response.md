Using story-find skill to surface stories touching this area + their validation state.

### us001 — order samples for upcoming client work   (match score: 5)

**As a** requestor, **I want** to order samples for upcoming client work, **because** I need product in hand for client tasting / presentation.

**Tags:** requestor-flow, catalog   **Status:** done

**Acceptance criteria:**
- [x] browse catalog of available samples
- [x] add items with quantity to a request
- [x] submit request to approver

Validated: 3/3 criteria met (status=done).

### us002 — track status of my submitted requests   (match score: 5)

**As a** requestor, **I want** track status of my submitted requests, **because** I need to know when samples will arrive so I can plan client visits.

**Tags:** requestor-flow, status   **Status:** draft

**Acceptance criteria:**
- [ ] list view of my requests with current status
- [ ] status reflects lifecycle (submitted, approved, rejected, dispatched)
- [ ] dispatched requests show tracking info if available

Unverified: 0/3 criteria checked (status=draft).

### us012 — save a sample request as a draft before submitting   (match score: 5)

**As a** requestor, **I want** save a sample request as a draft before submitting, **because** I may not have all the info yet (event date, exact items) and want to come back to it later.

**Tags:** requestor-flow, drafts   **Status:** draft

**Acceptance criteria:**
- [ ] explicit "save draft" action persists the request without submitting it
- [ ] my drafts appear in a separate list from submitted requests
- [ ] I can resume a draft, edit it, then submit or discard
- [ ] drafts are private to the requestor — not visible to approver, executor, or admin

Unverified: 0/4 criteria checked (status=draft).

### us013 — resubmit a Rejected or Blocked request after revising it   (match score: 5)

**As a** requestor, **I want** resubmit a Rejected or Blocked request after revising it, **because** I should not have to retype the whole request when the approver or executor flags an issue I can fix.

**Tags:** requestor-flow, resubmit   **Status:** draft

**Acceptance criteria:**
- [ ] rejected requests are editable by the original requestor (status stays Rejected until resubmit)
- [ ] blocked requests are editable by the original requestor (status stays Blocked until resubmit)
- [ ] resubmit transitions Rejected -> Submitted or Blocked -> Submitted on the same record
- [ ] version bumps on resubmit so prior approver/executor notes are preserved in history
- [ ] approver sees resubmitted item in pending queue again

Unverified: 0/5 criteria checked (status=draft).

Coverage for "requestor-flow": 4 matched stories — 1 done, 3 draft. Top match: us001 (score 5).
