Using story-read skill to surface the backlog.

# Product Backlog

## Draft

### us013 — resubmit a Rejected or Blocked request after revising it
**As a** requestor, **I want** to resubmit a rejected or blocked request after revising the items, **because** recreating the whole request from scratch is wasteful when most line items were fine.

- rejected request can be reopened from the rejected view
- previous line items pre-fill the new submission
- audit trail links the resubmission to the original

### us014 — bulk import requests from spreadsheet
**As a** requestor, **I want** to upload a spreadsheet to create many requests at once, **because** event prep means submitting dozens of similar requests and the per-row UI is slow.

- accept .xlsx and .csv uploads
- each row maps to one request with line items
- preview parsed rows before commit and reject bad rows with row-level error messages

## Ready

### us003 — track the status of my open requests
**As a** requestor, **I want** to see the status of every open request I submitted, **because** I want to know when I can pick up product without chasing the approver.

- requestor dashboard lists every request the user submitted
- each row shows the current status (Submitted / Approved / Rejected / Completed)
- closed requests older than 30 days are hidden by default

## Done

### us001 — order samples for upcoming client work
**As a** requestor, **I want** to order samples for upcoming client work, **because** I need product in hand for client tasting / presentation.

- browse catalog of available samples
- add items with quantity to a request
- submit request to approver

### us002 — approve or reject a request
**As an** approver, **I want** to approve or reject a submitted request, **because** the warehouse should only pick approved orders.

- approver sees pending requests in a queue
- approve sets status to Approved
- reject requires a comment and sets status to Rejected

Total: 5 stories (2 draft, 1 ready, 2 done).
