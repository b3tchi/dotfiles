#!/usr/bin/env bash
# Seed bd with ONE ready task plus a controllable-reviewer shim that
# flips approval based on a counter file in the sandbox:
#
#   $SANDBOX/.review_attempts/<task-id>  → integer N
#
# Reviewer behavior:
#   attempt 1  → REJECT with a specific, fixable reason
#   attempt 2  → APPROVE
#
# plan-scrum-master must:
#   - save the implementer's agent session metadata after the first dispatch
#   - on first rejection, resume the SAME agent via SendMessage (not spawn a fresh one)
#   - relay the reviewer's rejection details verbatim
#   - only escalate after a SECOND rejection (won't happen with this shim)
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
mkdir -p "$SANDBOX/.review_attempts"
cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"
git config user.name "eval"

cat > README.md <<'EOF'
# Acme Internal Platform — rejection-retry fixture

One ready task. Reviewer shim rejects attempt 1, approves attempt 2.
EOF

mkdir -p src/services/billing
echo "# Billing." > src/services/billing/__init__.py

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
.venv/
.review_attempts/
EOF

mkdir -p board/ready

cat > board/ready/billing-rounding.md <<'EOF'
# Billing: invoice rounding

**Goal:** round line items to 2dp using banker's rounding.
**Targets:** src/services/billing/

## Task 1: rounding helper
File: src/services/billing/rounding.py. Test: src/services/billing/test_rounding.py.
EOF

# Reviewer shim: callable from the reviewer agent's prompt. Tracks
# per-task attempt count and emits either REJECT or APPROVE.
cat > review_shim.sh <<'SHIM'
#!/usr/bin/env bash
# Usage: review_shim.sh <task-id> [implementer-report-path]
# Reads/increments $SANDBOX/.review_attempts/<task-id> and prints JSON:
#   { "verdict": "reject"|"approve", "reason": "..." }
set -euo pipefail
TASK_ID="${1:?task id required}"
SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
COUNTER_DIR="$SANDBOX_DIR/.review_attempts"
mkdir -p "$COUNTER_DIR"
COUNTER_FILE="$COUNTER_DIR/$TASK_ID"
CURRENT=0
[ -f "$COUNTER_FILE" ] && CURRENT=$(cat "$COUNTER_FILE")
NEXT=$((CURRENT + 1))
echo "$NEXT" > "$COUNTER_FILE"
if [ "$NEXT" -eq 1 ]; then
  cat <<JSON
{
  "verdict": "reject",
  "attempt": $NEXT,
  "reason": "test_rounding.py has only 2 tests; spec requires coverage of half-even tie-breaking (e.g., 2.5 → 2, 3.5 → 4). Add 2 more tests and ensure pytest passes.",
  "files_missing": ["test for 2.5→2 case", "test for 3.5→4 case"]
}
JSON
else
  cat <<JSON
{
  "verdict": "approve",
  "attempt": $NEXT,
  "summary": "Banker's rounding implemented; tie-breaking covered; pytest passes."
}
JSON
fi
SHIM
chmod +x review_shim.sh

git add . >/dev/null
git commit -q -m "seed: one ready task + reviewer shim that flips on attempt 2"

bd init --prefix eval --stealth --database "eval-rejection-retry-$$" >/dev/null

EPIC=$(bd q "Epic: invoice rounding")
bd update "$EPIC" --type epic --design "Round invoice line items to 2dp using banker's rounding."

T1=$(bd q "Billing rounding - Task 1: rounding helper")
bd update "$T1" --parent "$EPIC" --design "$(cat <<'EOF'
## Goal
Implement src/services/billing/rounding.py with banker's rounding.

## Success Criteria
- [ ] src/services/billing/rounding.py defines `bankers_round(value: Decimal, places: int) -> Decimal`
- [ ] src/services/billing/test_rounding.py covers: basic rounding, tie-breaking (half-even), negative values, zero — 4+ tests
- [ ] pytest passes

## Reviewer
Run the review_shim.sh in the sandbox root:
  bash $SANDBOX/review_shim.sh <task-id>
Parse the JSON. On verdict=reject, relay reason to implementer.
EOF
)"

cat > "$SANDBOX/seeded_ids.json" <<EOF
{
  "epic_rounding": "$EPIC",
  "t1_ready": "$T1",
  "review_shim": "$SANDBOX/review_shim.sh",
  "counter_dir": "$SANDBOX/.review_attempts"
}
EOF

echo "Seeded rejection-retry sandbox at $SANDBOX"
echo "Reviewer shim at $SANDBOX/review_shim.sh"
echo "Test:  bash $SANDBOX/review_shim.sh $T1"
echo
echo "--- bd ready ---"
bd ready
echo
echo "--- seeded ids ---"
cat "$SANDBOX/seeded_ids.json"
