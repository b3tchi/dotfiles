#!/usr/bin/env bash
# Seed a sandbox representing a tiny existing "platform" codebase so the skill
# has real project context to explore before asking clarifying questions.
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

Small internal services platform for Acme Corp. Mostly Python + Postgres;
a handful of Go workers. No external traffic — everything is behind the VPN.

## Conventions
- Services live under `src/services/<name>/`
- Shared models in `src/models/`
- Secrets via Vault (`src/lib/vault.py`)
- Deployed via internal ArgoCD

## Current services
- `auth`: SSO proxy
- `metrics`: Prometheus scraper

Please do not introduce external dependencies without an architecture review.
EOF

mkdir -p src/services/auth src/services/metrics src/models
cat > src/services/auth/__init__.py <<'EOF'
# SSO proxy service — not for external consumption.
EOF
cat > src/services/metrics/__init__.py <<'EOF'
# Prometheus scraper — internal use only.
EOF
cat > src/models/__init__.py <<'EOF'
# Shared SQLAlchemy models live here.
EOF

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
EOF

git add -A
git commit -q -m "seed: Acme internal platform skeleton"

# Record what was present at seed time so the grader can diff
find . -path ./.git -prune -o -type f -print | sort > "$SANDBOX/.seed_manifest.txt"

echo "Seeded sandbox at $SANDBOX"
