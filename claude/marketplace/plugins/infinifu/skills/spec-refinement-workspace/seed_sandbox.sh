#!/usr/bin/env bash
# Seed a fresh sandbox with a bd epic + 4 tasks that each stress a subset
# of the spec-refinement 8-category checklist.
#
# Usage: seed_sandbox.sh <sandbox-dir>
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"
git config user.name "eval"
touch .gitkeep
git add .gitkeep
git commit -q -m "init sandbox"

bd init --prefix eval --stealth >/dev/null

# Epic
EPIC_ID=$(bd q "Epic: VIN & License Plate Scanner")
bd update "$EPIC_ID" --type epic --design "$(cat <<'EOF'
## Goal
Build document scanners that detect VINs and US license plates inside customer files and redact them before storage.

## Child Tasks
- Task A: Implement VIN scanner
- Task B: Implement license-plate scanner family
- Task C: Data encryption at rest
- Task D: Model definition
EOF
)"

# Task A — has a placeholder and one vague criterion. 6h estimate. Well-sized.
A=$(bd q "Task A: Implement VIN scanner")
bd update "$A" --parent "$EPIC_ID" --design "$(cat <<'EOF'
## Goal
Implement VIN detection in document scanner.

## Effort Estimate
6 hours.

## Implementation Checklist
- [ ] Create src/scan/scanners/vin.rs
- [ ] [Complete implementation steps detailed above]
- [ ] Add tests

## Success Criteria
- [ ] VIN detection is implemented correctly
- [ ] [As specified in the implementation checklist]
- [ ] Tests pass

## Anti-patterns
- No unwrap/expect in production code.
EOF
)"

# Task B — 40-hour monster, no breakdown, no subtasks.
B=$(bd q "Task B: License-plate scanner family (US states)")
bd update "$B" --parent "$EPIC_ID" --design "$(cat <<'EOF'
## Goal
Implement license-plate detection for all 50 US states, with healthcare context check, per-state regex, ambiguous-char rules, false-positive suppression, configurable confidence thresholds, and a benchmark harness.

## Effort Estimate
~40 hours total.

## Implementation Checklist
- [ ] Define state format catalog (50 states)
- [ ] Per-state regex implementations
- [ ] Generic fallback pattern
- [ ] Healthcare context detector
- [ ] False-positive suppression rules
- [ ] Confidence scoring
- [ ] Benchmark harness
- [ ] Full test suite

## Success Criteria
- [ ] Scanner works across all 50 states
- [ ] Healthcare context respected
- [ ] No unwrap/expect

## Anti-patterns
- No unwrap/expect.
EOF
)"

# Task C — parsing-heavy task with zero edge-case analysis.
C=$(bd q "Task C: Data encryption at rest")
bd update "$C" --parent "$EPIC_ID" --design "$(cat <<'EOF'
## Goal
Add at-rest encryption for scanned documents before persistence. Use AES-256 with a per-document key.

## Effort Estimate
8 hours.

## Implementation Checklist
- [ ] Create src/crypto/at_rest.rs with encrypt()/decrypt()
- [ ] Wire into storage layer
- [ ] Add happy-path encode/decode unit test

## Success Criteria
- [ ] test_encode_decode passes (round-trip)
- [ ] test_encrypts_file_exists passes (file exists after encrypt)
- [ ] Code compiles

## Anti-patterns
- No hardcoded keys.
EOF
)"

# Task D — tautological tests. Compiler-checked "struct has field" tests.
D=$(bd q "Task D: Define ScanResult data model")
bd update "$D" --parent "$EPIC_ID" --design "$(cat <<'EOF'
## Goal
Define the ScanResult struct in src/models.rs with fields for scanner_id, match_count, redacted_content.

## Effort Estimate
3 hours.

## Implementation Checklist
- [ ] Define struct
- [ ] Derive Debug, Clone, PartialEq
- [ ] Add unit tests

## Success Criteria
- [ ] test_scan_result_has_scanner_id_field passes
- [ ] test_scan_result_has_match_count_field passes
- [ ] test_scan_result_can_be_constructed passes
- [ ] test_scan_result_derives_debug passes
- [ ] Code compiles.

## Anti-patterns
- None specific.
EOF
)"

# .beads/ is in .git/info/exclude (stealth mode); grader reads state directly
# from `bd list` so a git commit is unnecessary.

# Record the IDs for the grader
cat > "$SANDBOX/seeded_ids.json" <<EOF
{
  "epic": "$EPIC_ID",
  "task_a_placeholder": "$A",
  "task_b_oversized": "$B",
  "task_c_no_edges": "$C",
  "task_d_tautological": "$D"
}
EOF

echo "Seeded sandbox at $SANDBOX"
echo "IDs:"
cat "$SANDBOX/seeded_ids.json"
