#!/usr/bin/env bash
# Seed bd with ONE ready task whose design is deliberately insufficient.
# A real implementer agent should set the task to blocked because the
# requirements are too vague to act on. plan-scrum-master must surface
# the blocked report immediately and stop dispatching.
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"
git config user.name "eval"

cat > README.md <<'EOF'
# Acme Internal Platform — blocked-escalation fixture

The one ready task has design = "TBD". Implementer should mark blocked.
EOF

mkdir -p src/services/thing
echo "# Thing service." > src/services/thing/__init__.py

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
.venv/
EOF

mkdir -p board/ready

cat > board/ready/thing-feature.md <<'EOF'
# Thing: feature plan

> **For Claude:** plan-scrum-master.

**Goal:** TBD.
**Architecture:** TBD.
**Tech Stack:** Python.

## Task 1: implement the thing
Files: TBD.
EOF

git add . >/dev/null
git commit -q -m "seed: one ready task with TBD design"

bd init --prefix eval --stealth --database "eval-blocked-escalation-$$" >/dev/null

EPIC=$(bd q "Epic: Thing feature")
bd update "$EPIC" --type epic --design "$(cat <<'EOF'
## Goal
TBD — see board/ready/thing-feature.md (deliberately under-specified).

## Spec
board/ready/thing-feature.md

## Targets
src/services/thing/
EOF
)"

T1=$(bd q "Thing - Task 1: implement the thing")
bd update "$T1" --parent "$EPIC" --design "Implement the thing. TBD."

cat > "$SANDBOX/seeded_ids.json" <<EOF
{
  "epic_thing": "$EPIC",
  "t1_ready": "$T1"
}
EOF

echo "Seeded blocked-escalation sandbox at $SANDBOX"
echo
echo "--- bd ready ---"
bd ready
echo
echo "--- seeded ids ---"
cat "$SANDBOX/seeded_ids.json"
