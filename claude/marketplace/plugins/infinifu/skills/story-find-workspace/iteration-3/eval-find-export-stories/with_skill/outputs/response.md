Using story-find skill to surface stories touching this area + their validation state.

### 2605-001 — Export query results as CSV   (match score: 10)

**As a** data analyst, **I want** to export query results as CSV, **so that** I can share them with non-technical stakeholders.

**Tags:** export, data   **Status:** done

**Acceptance criteria:**
- [x] CSV download includes all visible columns in the same order as the table
- [x] Empty result set returns a CSV with only the header row
- [x] Download triggers within 2 seconds for ≤10k rows

Validated: 3/3 criteria met (status=done).

### 2605-004 — Export reports as PDF   (match score: 10)

**As a** manager, **I want** to export weekly reports as PDF, **so that** I can email them to executives.

**Tags:** export, reports   **Status:** draft

**Acceptance criteria:**
- [ ] PDF includes company logo header
- [ ] PDF is paginated by section
- [ ] PDF download size is under 5MB

Unverified: 0/3 criteria checked (status=draft).

Coverage for "Which stories cover the export feature?": 2 matched stories — 1 done, 0 ready, 1 draft. Top match: 2605-001 (score 10).
