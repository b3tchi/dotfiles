Using story-find skill to surface stories touching this area + their validation state.

**Query:** "Are there stories about resubmission?"
**Tokens:** `["resubmission", "resubmit"]` (morphological variant included so the `[[resubmit]]` tag scores)

Yes — 2 stories relate to resubmission.

### us013 — resubmit a Rejected or Blocked request after revising it   (match score: 12)

**As a** requestor, **I want** resubmit a Rejected or Blocked request after revising it, **because** I should not have to retype the whole request when the approver or executor flags an issue I can fix.

**Tags:** requestor-flow, resubmit   **Status:** draft

**Acceptance criteria:**
- [ ] rejected requests are editable by the original requestor (status stays Rejected until resubmit)
- [ ] blocked requests are editable by the original requestor (status stays Blocked until resubmit)
- [ ] resubmit transitions Rejected -> Submitted or Blocked -> Submitted on the same record
- [ ] version bumps on resubmit so prior approver/executor notes are preserved in history
- [ ] approver sees resubmitted item in pending queue again

Unverified: 0/5 criteria checked (status=draft).

### us008 — flag stock shortage on a request that cannot be fulfilled   (match score: 2)

**As a** executor, **I want** flag stock shortage on a request that cannot be fulfilled, **because** requestor and approver must know before the deadline that the order will not ship.

**Tags:** dispatch, exception   **Status:** draft

**Acceptance criteria:**
- [ ] per-line shortage flag with optional substitute item or revised quantity
- [ ] request transitions Approved -> Blocked
- [ ] blocked request routes back to requestor (not approver) for revision and resubmission
- [ ] requestor sees blocked state with executor's shortage notes

Unverified: 0/4 criteria checked (status=draft).

---

Coverage for "resubmission": 2 matched stories — 2 draft. Top match: us013 (score 12). us008 is a weak match (score 2) — it only mentions resubmission tangentially as a downstream effect of a blocked request; us013 is the primary story for the resubmission flow.
