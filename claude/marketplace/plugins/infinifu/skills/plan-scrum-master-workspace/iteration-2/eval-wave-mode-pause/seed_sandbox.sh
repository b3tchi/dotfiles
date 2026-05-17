#!/usr/bin/env bash
# Seed bd with 2 non-interfering epics × 2 ready tasks (4 ready total).
# plan-scrum-master in mode=waves must dispatch ONE batch of 2, drain it,
# then HALT and ask for feedback — NOT dispatch the remaining 2.
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"
git config user.name "eval"

cat > README.md <<'EOF'
# Acme Internal Platform — wave-mode fixture

Two non-interfering epics, 2 ready tasks each. Tests wave-mode pause.
EOF

mkdir -p src/services/auth src/services/billing
echo "# Auth service." > src/services/auth/__init__.py
echo "# Billing service." > src/services/billing/__init__.py

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
.venv/
EOF

mkdir -p board/ready

cat > board/ready/auth-2fa.md <<'EOF'
# Auth: 2FA Plan

**Goal:** TOTP 2FA.
**Targets:** src/services/auth/

## Task 1: TOTP generator
File: src/services/auth/totp.py.

## Task 2: 2FA endpoint
File: src/services/auth/two_factor.py (no overlap with task 1).
EOF

cat > board/ready/billing-pdf.md <<'EOF'
# Billing: PDF Plan

**Goal:** Generate invoice PDFs.
**Targets:** src/services/billing/

## Task 1: PDF renderer
File: src/services/billing/pdf.py.

## Task 2: invoice route
File: src/services/billing/invoice.py.
EOF

git add . >/dev/null
git commit -q -m "seed: 2 non-interfering epics x 2 ready tasks"

bd init --prefix eval --stealth --database "eval-wave-mode-pause-$$" >/dev/null

# Epic A — 2FA, 2 independent ready tasks
EPIC_A=$(bd q "Epic: Auth 2FA")
bd update "$EPIC_A" --type epic --design "Add TOTP 2FA. Targets: src/services/auth/"

A1=$(bd q "Auth 2FA - Task 1: TOTP generator")
bd update "$A1" --parent "$EPIC_A" --design "Implement src/services/auth/totp.py — TOTP gen + verify. Test src/services/auth/test_totp.py."

A2=$(bd q "Auth 2FA - Task 2: 2FA endpoint")
bd update "$A2" --parent "$EPIC_A" --design "Implement src/services/auth/two_factor.py — challenge endpoint. Test src/services/auth/test_two_factor.py. Independent of Task 1 (no file overlap)."

# Epic B — billing PDF, 2 independent ready tasks
EPIC_B=$(bd q "Epic: Billing PDF")
bd update "$EPIC_B" --type epic --design "Generate PDF invoices. Targets: src/services/billing/"

B1=$(bd q "Billing PDF - Task 1: renderer")
bd update "$B1" --parent "$EPIC_B" --design "Implement src/services/billing/pdf.py — render template to PDF bytes."

B2=$(bd q "Billing PDF - Task 2: route")
bd update "$B2" --parent "$EPIC_B" --design "Implement src/services/billing/invoice.py — GET /billing/invoice/{id}/pdf. Independent of Task 1 (no file overlap)."

cat > "$SANDBOX/seeded_ids.json" <<EOF
{
  "epic_auth": "$EPIC_A",
  "epic_billing": "$EPIC_B",
  "a1_ready": "$A1",
  "a2_ready": "$A2",
  "b1_ready": "$B1",
  "b2_ready": "$B2"
}
EOF

echo "Seeded wave-mode sandbox at $SANDBOX"
echo
echo "--- bd ready ---"
bd ready
echo
echo "--- seeded ids ---"
cat "$SANDBOX/seeded_ids.json"
