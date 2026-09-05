#!/usr/bin/env bash
# Run every validation suite that guards the runtime-neutral lifecycle contract
# (sp027 / ft013), including the suites earlier tasks left in their own
# workspaces. One command, nonzero exit on any failure.
#
# Bash rather than nushell per adr0002: this is glue that shells out to the
# python suites and reports exit codes; it matches the existing workspace
# runners (seed_sandbox.sh, run_optimization.sh) and work-merge/scripts/*.sh.
set -uo pipefail

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUITES=(
  "lifecycle-contract-workspace/test_runtime_selection_contract.py"
  "lifecycle-contract-workspace/test_feature_add_lifecycle_contract.py"
  "plan-scrum-master-workspace/test_orchestration_runtime_contract.py"
  "work-lineage-workspace/test_work_lineage_contract.py"
  "work-merge-workspace/test_archive_epic.py"
  "spec-retro-workspace/test_feature_add_retro_grader.py"
)

failed=()
missing=()

for suite in "${SUITES[@]}"; do
  path="$SKILLS_DIR/$suite"
  if [[ ! -f "$path" ]]; then
    # A suite named here but absent is a failure, not a silent skip: it means a
    # contract someone wrote a test for is no longer being checked.
    printf 'MISSING  %s\n' "$suite"
    missing+=("$suite")
    continue
  fi
  if python3 "$path" >/tmp/lifecycle-validation.$$ 2>&1; then
    printf 'PASS     %s (%s)\n' "$suite" "$(grep -oE '^Ran [0-9]+ tests?' /tmp/lifecycle-validation.$$ | head -1)"
  else
    printf 'FAIL     %s\n' "$suite"
    sed 's/^/         /' /tmp/lifecycle-validation.$$
    failed+=("$suite")
  fi
  rm -f /tmp/lifecycle-validation.$$
done

if (( ${#failed[@]} == 0 && ${#missing[@]} == 0 )); then
  printf '\nAll %d lifecycle contract suites passed.\n' "${#SUITES[@]}"
  exit 0
fi

printf '\n%d failed, %d missing, of %d suites.\n' \
  "${#failed[@]}" "${#missing[@]}" "${#SUITES[@]}"
exit 1
