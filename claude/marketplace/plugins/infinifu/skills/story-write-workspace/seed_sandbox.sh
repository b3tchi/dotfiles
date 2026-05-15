#!/usr/bin/env bash
# Seed an AKM sandbox for story-write evals.
#
# Default mode: existing workspace with personas + 5 stories (us001-us014).
#   Next story will be us015 or higher.
# --fresh mode: empty docs/notes/ (no us*.md, no pn*.md).
#   Tests first-story-of-workspace path. Hub + akm.md still present.
#
# Schema source of truth: docs/notes/akm.md (Agentic Knowledge Model).
#
# Usage:
#   seed_sandbox.sh <sandbox-dir>
#   seed_sandbox.sh --fresh <sandbox-dir>
set -euo pipefail

FRESH=0
if [ "${1:-}" = "--fresh" ]; then
  FRESH=1
  shift
fi

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/docs/notes"
cd "$SANDBOX"

# Product hub — always present
if [ "$FRESH" = "1" ]; then
  cat > docs/product.md <<'EOF'
# Product

Sample-ordering workflow.

## Stories

## AKM Reference

- [[akm]] — knowledge model: every zettel type, its schema and life-cycle
EOF
else
  cat > docs/product.md <<'EOF'
# Product

Sample-ordering workflow.

## Stories

### [[pn001|requestor]]

- [[us001|order samples for upcoming client work]]
- [[us003|track the status of my open requests]]
- [[us013|resubmit a Rejected or Blocked request after revising it]]
- [[us014|bulk import requests from spreadsheet]]

### [[pn002|approver]]

- [[us002|approve or reject a request]]

## AKM Reference

- [[akm]] — knowledge model: every zettel type, its schema and life-cycle
EOF
fi

# Minimal akm.md so skills can reference the schema
cat > docs/notes/akm.md <<'EOF'
---
aliases:
  - agentic knowledge model
status: stable
created: 2026-05-14
---
# AKM — Agentic Knowledge Model [[product]]

Story zettels live at docs/notes/us###.md with frontmatter
(aliases, status, created) and body sections role / want / because /
acceptance_criteria. Required: [[product]] in H1, [[pn###|alias]] for
role, 'Index: [[product]]' footer.

ID format: us### (3-digit zero-padded sequential). Status values:
draft, ready, in_progress, done, dropped.

---

Index: [[product]]
EOF

if [ "$FRESH" = "1" ]; then
  echo "Seeded fresh AKM sandbox at $SANDBOX (empty docs/notes/, no personas, no stories)."
  exit 0
fi

# Personas
cat > docs/notes/pn001.md <<'EOF'
---
aliases:
  - requestor
status: validated
created: 2026-05-01
---
# Persona [[product]]

## name
Sample Requestor

## summary
Front-line salesperson who pulls samples for client meetings.

---

Index: [[product]]
EOF

cat > docs/notes/pn002.md <<'EOF'
---
aliases:
  - approver
status: validated
created: 2026-05-01
---
# Persona [[product]]

## name
Sample Approver

## summary
Manager who reviews and approves requestor submissions.

---

Index: [[product]]
EOF

# Stories spanning the lifecycle
cat > docs/notes/us001.md <<'EOF'
---
aliases:
  - order samples for upcoming client work
status: done
created: 2026-05-01
---
# Story [[requestor-flow]] [[catalog]] [[product]]

## role
[[pn001|requestor]]

## want
order samples for upcoming client work

## because
I need product in hand for client tasting / presentation

## acceptance_criteria
- browse catalog of available samples
- add items with quantity to a request
- submit request to approver

---

Index: [[product]]
EOF

cat > docs/notes/us002.md <<'EOF'
---
aliases:
  - approve or reject a request
status: done
created: 2026-05-02
---
# Story [[approver-flow]] [[product]]

## role
[[pn002|approver]]

## want
approve or reject a submitted request

## because
the warehouse should only pick approved orders

## acceptance_criteria
- approver sees pending requests in a queue
- approve sets status to Approved
- reject requires a comment and sets status to Rejected

---

Index: [[product]]
EOF

cat > docs/notes/us003.md <<'EOF'
---
aliases:
  - track the status of my open requests
status: ready
created: 2026-05-05
---
# Story [[requestor-flow]] [[tracking]] [[product]]

## role
[[pn001|requestor]]

## want
see the status of every open request I submitted

## because
I want to know when I can pick up product without chasing the approver

## acceptance_criteria
- requestor dashboard lists every request the user submitted
- each row shows the current status
- closed requests older than 30 days are hidden by default

---

Index: [[product]]
EOF

cat > docs/notes/us013.md <<'EOF'
---
aliases:
  - resubmit a Rejected or Blocked request after revising it
status: draft
created: 2026-05-12
---
# Story [[requestor-flow]] [[product]]

## role
[[pn001|requestor]]

## want
resubmit a rejected or blocked request after revising the items

## because
recreating the whole request from scratch is wasteful

## acceptance_criteria
- rejected request can be reopened from the rejected view
- previous line items pre-fill the new submission
- audit trail links the resubmission to the original

---

Index: [[product]]
EOF

cat > docs/notes/us014.md <<'EOF'
---
aliases:
  - bulk import requests from spreadsheet
status: draft
created: 2026-05-13
---
# Story [[requestor-flow]] [[import]] [[product]]

## role
[[pn001|requestor]]

## want
upload a spreadsheet to create many requests at once

## because
event prep means submitting dozens of similar requests and the per-row UI is slow

## acceptance_criteria
- accept .xlsx and .csv uploads
- each row maps to one request with line items
- preview parsed rows before commit and reject bad rows

---

Index: [[product]]
EOF

echo "Seeded AKM sandbox at $SANDBOX (2 personas, 5 stories — next id is us015)."
