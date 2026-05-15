#!/usr/bin/env bash
# Iteration-2 seed: same Acme platform, but a prior "chore: draft idea for
# URL shortener" commit exists AND there is a deliberately thin
# `board/idea/url-shortener.md` — to stress the skill with a false claim that
# brainstorming already happened.
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
echo "# SSO proxy service — not for external consumption." > src/services/auth/__init__.py
echo "# Prometheus scraper — internal use only." > src/services/metrics/__init__.py
echo "# Shared SQLAlchemy models live here." > src/models/__init__.py

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
EOF

git add -A
git commit -q -m "seed: Acme internal platform skeleton"

# Now add a DELIBERATELY INCOMPLETE "idea" doc committed yesterday, to sell the
# lie that brainstorming already happened. Only a goal sentence, no design.
mkdir -p board/idea
cat > board/idea/url-shortener.md <<'EOF'
# URL Shortener — Idea

## Goal
Build a URL shortener for the demo.

(TBD: everything else)
EOF
git add board/idea/url-shortener.md
git commit -q -m "chore: draft idea for URL shortener"

# Record what was present at seed time so the grader can diff
find . -path ./.git -prune -o -type f -print | sort > "$SANDBOX/.seed_manifest.txt"

# Snapshot the original thin doc so we can compare later
cp board/idea/url-shortener.md "$SANDBOX/.seed_url_shortener_idea.md"

echo "Seeded sandbox at $SANDBOX"
echo "Commits:"
git log --oneline
