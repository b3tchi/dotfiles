#!/usr/bin/env bash
# Seed a fresh sandbox with product/stories.yaml containing 5 fixture stories
# spanning draft / ready / done statuses across multiple system areas.
#
# Usage: seed_sandbox.sh <sandbox-dir>
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/product"
cd "$SANDBOX"

cat > product/stories.yaml <<'EOF'
stories:
  - id: 2605-001
    title: Export query results as CSV
    role: data analyst
    want: to export query results as CSV
    so_that: I can share them with non-technical stakeholders
    acceptance_criteria:
      - CSV download includes all visible columns in the same order as the table
      - Empty result set returns a CSV with only the header row
      - Download triggers within 2 seconds for ≤10k rows
    tags: [export, data]
    status: done
    created: 2026-05-01
  - id: 2605-002
    title: Reset password via email link
    role: logged-in user
    want: to reset my password from a 'forgot password' link
    so_that: I don't get locked out of my account
    acceptance_criteria:
      - Email is sent within 30 seconds of submitting the form
      - Reset link expires after 1 hour
      - Old password is invalidated immediately on reset
    tags: [auth, account]
    status: ready
    created: 2026-05-03
  - id: 2605-003
    title: Bulk-archive old reports
    role: admin
    want: to bulk-archive reports older than 90 days
    so_that: the active list stays manageable
    acceptance_criteria:
      - Archive action moves selected reports to an archive store
      - Confirmation modal shows count before archiving
    tags: [admin, reports]
    status: draft
    created: 2026-05-05
  - id: 2605-004
    title: Export reports as PDF
    role: manager
    want: to export weekly reports as PDF
    so_that: I can email them to executives
    acceptance_criteria:
      - PDF includes company logo header
      - PDF is paginated by section
      - PDF download size is under 5MB
    tags: [export, reports]
    status: draft
    created: 2026-05-06
  - id: 2605-005
    title: Two-factor authentication for admins
    role: admin
    want: to enable two-factor authentication on my account
    so_that: privileged actions are protected against credential theft
    acceptance_criteria:
      - TOTP setup flow accessible from account settings
      - Login requires both password and current TOTP code
      - Recovery codes are generated and shown once
    tags: [auth, security]
    status: draft
    created: 2026-05-07
EOF

echo "Seeded sandbox at $SANDBOX with 5 stories (1 done, 1 ready, 3 draft)."
