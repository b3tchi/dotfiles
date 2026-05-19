#!/usr/bin/env bash
# Seed a bd project with TWO ready epics (non-interfering) + a stale
# in_progress task from a prior session. Tests orient + interference check
# + the human-confirmation gate.
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"
git config user.name "eval"

cat > README.md <<'EOF'
# Acme Internal Platform

Python + FastAPI + Postgres. Services under `src/services/<name>/`.
EOF

mkdir -p src/services/auth src/services/billing src/services/metrics
echo "# SSO proxy." > src/services/auth/__init__.py
echo "# Billing service." > src/services/billing/__init__.py
echo "# Prometheus scraper." > src/services/metrics/__init__.py

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
.venv/
EOF

# Ready spec docs for each epic
mkdir -p board/ready
cat > board/ready/auth-2fa.md <<'EOF'
# Auth: 2FA Support Implementation Plan

> **For Claude:** plan-scrum-master.

**Goal:** Add TOTP 2FA to the auth service.
**Architecture:** New endpoints under `src/services/auth/`; shared model under `src/models/totp.py`.
**Tech Stack:** FastAPI, pyotp, SQLAlchemy.

## Task 1: TOTP generator
Files: Create `src/services/auth/totp.py`, Test: `tests/services/auth/test_totp.py`.

## Task 2: 2FA challenge endpoint
Files: Modify `src/services/auth/app.py`, Test: `tests/services/auth/test_challenge.py`.
(depends on Task 1)
EOF

cat > board/ready/billing-pdf.md <<'EOF'
# Billing: Invoice PDF Implementation Plan

> **For Claude:** plan-scrum-master.

**Goal:** Generate PDF invoices on demand.
**Architecture:** New renderer at `src/services/billing/pdf.py`; wire into `src/services/billing/app.py`.
**Tech Stack:** FastAPI, weasyprint, Jinja2.

## Task 1: PDF template renderer
Files: Create `src/services/billing/pdf.py`, Test: `tests/services/billing/test_pdf.py`.

## Task 2: Invoice PDF endpoint
Files: Modify `src/services/billing/app.py`, Test: `tests/services/billing/test_invoice_pdf.py`.
(depends on Task 1)
EOF

git add -A
git commit -q -m "seed: Acme platform + two ready epics"

bd init --prefix eval --stealth >/dev/null

# Epic A — auth 2FA
EPIC_A=$(bd q "Epic: Auth 2FA")
bd update "$EPIC_A" --type epic --design "$(cat <<'EOF'
## Goal
Add TOTP 2FA to the auth service.

## Spec
board/ready/auth-2fa.md

## Targets
src/services/auth/, src/models/totp.py, tests/services/auth/
EOF
)"

A1=$(bd q "Auth 2FA - Task 1: TOTP generator")
bd update "$A1" --parent "$EPIC_A" --design "$(cat <<'EOF'
## Goal
Implement a TOTP generator at src/services/auth/totp.py.

## Success Criteria
- [ ] tests/services/auth/test_totp.py has 4+ tests covering generation, verification, window tolerance, invalid secret
- [ ] pytest passes
EOF
)"

A2=$(bd q "Auth 2FA - Task 2: 2FA challenge endpoint")
bd update "$A2" --parent "$EPIC_A" --design "$(cat <<'EOF'
## Goal
Add POST /auth/2fa/challenge that verifies a TOTP code.

## Success Criteria
- [ ] tests/services/auth/test_challenge.py 3+ tests
- [ ] pytest passes
EOF
)"
bd dep add "$A2" "$A1"  # A2 blocked by A1

# Epic B — billing PDF
EPIC_B=$(bd q "Epic: Billing invoice PDF")
bd update "$EPIC_B" --type epic --design "$(cat <<'EOF'
## Goal
Generate PDF invoices.

## Spec
board/ready/billing-pdf.md

## Targets
src/services/billing/, tests/services/billing/
EOF
)"

B1=$(bd q "Billing PDF - Task 1: PDF template renderer")
bd update "$B1" --parent "$EPIC_B" --design "$(cat <<'EOF'
## Goal
Implement PDF template renderer at src/services/billing/pdf.py.

## Success Criteria
- [ ] tests/services/billing/test_pdf.py has 3+ tests
- [ ] pytest passes
EOF
)"

B2=$(bd q "Billing PDF - Task 2: Invoice PDF endpoint")
bd update "$B2" --parent "$EPIC_B" --design "$(cat <<'EOF'
## Goal
Wire GET /billing/invoice/{id}/pdf.

## Success Criteria
- [ ] tests/services/billing/test_invoice_pdf.py 2+ tests
EOF
)"
bd dep add "$B2" "$B1"  # B2 blocked by B1

# Stale task from a previous session — deliberately left in_progress to test
# that plan-scrum-master detects and flags it.
STALE=$(bd q "Refactor: legacy config reader")
bd update "$STALE" --design "## Goal
Refactor src/lib/config.py to use pydantic-settings." --status in_progress

cat > "$SANDBOX/seeded_ids.json" <<EOF
{
  "epic_auth": "$EPIC_A",
  "epic_billing": "$EPIC_B",
  "a1_ready": "$A1",
  "a2_blocked": "$A2",
  "b1_ready": "$B1",
  "b2_blocked": "$B2",
  "stale_in_progress": "$STALE"
}
EOF

echo "Seeded sandbox at $SANDBOX"
echo
echo "--- bd ready ---"
bd ready
echo
echo "--- seeded ids ---"
cat "$SANDBOX/seeded_ids.json"
