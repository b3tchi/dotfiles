#!/usr/bin/env bash
# Seed a bd project with TWO ready epics that DO interfere — both touch
# src/services/auth/. plan-scrum-master must detect the conflict and
# serialize (dispatch only one epic's task in the first batch).
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"
git config user.name "eval"

cat > README.md <<'EOF'
# Acme Internal Platform — interference fixture

Python + FastAPI + Postgres. Both ready epics modify the same service tree.
EOF

mkdir -p src/services/auth src/services/auth/middleware
echo "# Auth service." > src/services/auth/__init__.py
echo "# Middleware." > src/services/auth/middleware/__init__.py

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
.venv/
EOF

mkdir -p board/ready

cat > board/ready/auth-2fa.md <<'EOF'
# Auth: 2FA Support Implementation Plan

> **For Claude:** plan-scrum-master.

**Goal:** Add TOTP 2FA to the auth service.
**Architecture:** New endpoints in `src/services/auth/`; touches `src/services/auth/middleware/__init__.py` for the challenge interceptor.
**Tech Stack:** FastAPI, pyotp.

## Task 1: TOTP generator
Files: Create `src/services/auth/totp.py`.

## Task 2: 2FA middleware
Files: Modify `src/services/auth/middleware/__init__.py`, add challenge step.
(depends on Task 1)
EOF

cat > board/ready/auth-rate-limit.md <<'EOF'
# Auth: Rate-limit middleware Implementation Plan

> **For Claude:** plan-scrum-master.

**Goal:** Add a sliding-window rate limiter to auth endpoints.
**Architecture:** Modifies `src/services/auth/middleware/__init__.py` and adds `src/services/auth/limiter.py`.
**Tech Stack:** FastAPI, redis.

## Task 1: limiter module
Files: Create `src/services/auth/limiter.py`.

## Task 2: wire into middleware
Files: Modify `src/services/auth/middleware/__init__.py`.
(depends on Task 1)
EOF

git add . >/dev/null
git commit -q -m "seed: two interfering ready epics on src/services/auth/"

bd init --prefix eval --stealth >/dev/null

# Epic A — auth 2FA
EPIC_A=$(bd q "Epic: Auth 2FA")
bd update "$EPIC_A" --type epic --design "$(cat <<'EOF'
## Goal
Add TOTP 2FA to the auth service.

## Spec
board/ready/auth-2fa.md

## Targets
src/services/auth/totp.py, src/services/auth/middleware/__init__.py
EOF
)"

A1=$(bd q "Auth 2FA - Task 1: TOTP generator")
bd update "$A1" --parent "$EPIC_A" --design "Implement src/services/auth/totp.py with TOTP generation + verification."

A2=$(bd q "Auth 2FA - Task 2: 2FA middleware")
bd update "$A2" --parent "$EPIC_A" --design "Modify src/services/auth/middleware/__init__.py to add challenge interceptor."
bd dep add "$A2" "$A1"

# Epic B — auth rate-limit (interferes with Epic A via middleware/__init__.py)
EPIC_B=$(bd q "Epic: Auth rate-limit")
bd update "$EPIC_B" --type epic --design "$(cat <<'EOF'
## Goal
Add sliding-window rate limiter to auth endpoints.

## Spec
board/ready/auth-rate-limit.md

## Targets
src/services/auth/limiter.py, src/services/auth/middleware/__init__.py
EOF
)"

B1=$(bd q "Auth rate-limit - Task 1: limiter module")
bd update "$B1" --parent "$EPIC_B" --design "Create src/services/auth/limiter.py with sliding-window logic."

B2=$(bd q "Auth rate-limit - Task 2: wire into middleware")
bd update "$B2" --parent "$EPIC_B" --design "Modify src/services/auth/middleware/__init__.py to call limiter before auth check."
bd dep add "$B2" "$B1"

cat > "$SANDBOX/seeded_ids.json" <<EOF
{
  "epic_2fa": "$EPIC_A",
  "epic_ratelimit": "$EPIC_B",
  "a1_ready": "$A1",
  "a2_blocked": "$A2",
  "b1_ready": "$B1",
  "b2_blocked": "$B2",
  "shared_file": "src/services/auth/middleware/__init__.py"
}
EOF

echo "Seeded interfering sandbox at $SANDBOX"
echo
echo "--- bd ready ---"
bd ready
echo
echo "--- seeded ids ---"
cat "$SANDBOX/seeded_ids.json"
