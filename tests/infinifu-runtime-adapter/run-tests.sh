#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="$ROOT/claude/marketplace/plugins/infinifu/skills/meta-patterns/runtime-adapter.md"
PI_EXTENSION="$ROOT/claude/marketplace/plugins/infinifu/extensions/pi.ts"

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if ! grep -Eq -- "$pattern" "$file"; then
    printf 'FAIL: %s\n  file: %s\n  pattern: %s\n' "$description" "$file" "$pattern" >&2
    return 1
  fi
}

assert_file_contains "$CONTRACT" 'AI_AGENT=pi' 'contract documents the Pi runtime branch'
assert_file_contains "$CONTRACT" 'Claude[^\n]*(native|Agent|Task)[^\n]*(surface|tool)|native[^\n]*Claude[^\n]*(surface|Agent|Task)' 'contract documents the Claude-native runtime branch'
assert_file_contains "$CONTRACT" 'unsupported-runtime|unsupported runtime' 'contract documents unsupported-runtime failure'
assert_file_contains "$CONTRACT" 'Direct messaging remains the primary control channel' 'contract keeps direct messaging as primary control channel'
assert_file_contains "$CONTRACT" 'Durable state remains in `akm`, `bd`, and Git' 'contract keeps durable state in akm, bd, and Git'
assert_file_contains "$CONTRACT" 'required validation[[:space:]]+passes' 'contract requires validation before completion'
assert_file_contains "$CONTRACT" 'result' 'contract defines compact return result field'
assert_file_contains "$CONTRACT" 'validation verdict' 'contract defines compact return validation field'
assert_file_contains "$CONTRACT" 'visible worker name' 'contract defines compact return worker field'
assert_file_contains "$CONTRACT" 'exact resume command' 'contract defines compact return resume field'

assert_file_contains "$PI_EXTENSION" 'subagents are not built into Pi' 'Pi mapping says Claude subagents are unavailable'
assert_file_contains "$PI_EXTENSION" 'Never pretend a subagent was dispatched|must not be (simulated|pretended)' 'Pi mapping forbids simulated subagents'

SPEC_WRITING="$ROOT/claude/marketplace/plugins/infinifu/skills/spec-writing/SKILL.md"
SPEC_REFINEMENT="$ROOT/claude/marketplace/plugins/infinifu/skills/spec-refinement/SKILL.md"
SPEC_READY="$ROOT/claude/marketplace/plugins/infinifu/skills/spec-ready/SKILL.md"
SPEC_REFINEMENT_EVALS="$ROOT/claude/marketplace/plugins/infinifu/skills/spec-refinement-workspace/evals.json"
SPEC_REFINEMENT_GRADER="$ROOT/claude/marketplace/plugins/infinifu/skills/spec-refinement-workspace/grade.py"

assert_file_contains "$SPEC_WRITING" 'akm read sp###|akm read <sp###>|akm read' 'spec-writing names akm for AKM artifact access'
assert_file_contains "$SPEC_WRITING" 'feature-add' 'spec-writing documents feature-add lifecycle semantics'
assert_file_contains "$SPEC_WRITING" 'mint(s|ed)? `?ft###`?' 'spec-writing documents minting the proposed feature for feature-add specs'
assert_file_contains "$SPEC_WRITING" 'story-backed specs?' 'spec-writing keeps story-backed semantics explicit'

assert_file_contains "$SPEC_REFINEMENT" 'feature-add specs? may refine without (a )?source `?us###`?' 'spec-refinement permits feature-add specs without source story'
assert_file_contains "$SPEC_REFINEMENT" 'without (a )?consumed `?im###`?|no consumed `?im###`?' 'spec-refinement permits feature-add specs without consumed implementation'
assert_file_contains "$SPEC_REFINEMENT" 'proposed `?ft###`? is the deliverable' 'spec-refinement requires proposed feature deliverable for feature-add'
assert_file_contains "$SPEC_REFINEMENT" 'story-backed specs? still require' 'spec-refinement keeps story-backed us/im gate'
assert_file_contains "$SPEC_REFINEMENT" 'per-task SRE evidence matrix' 'spec-refinement requires per-task SRE evidence matrix'
assert_file_contains "$SPEC_REFINEMENT" 'generic .*SRE PASS.* rejected|reject.*generic .*SRE PASS' 'spec-refinement rejects generic SRE pass assertions'
assert_file_contains "$SPEC_REFINEMENT" 'Do not fabricate|no fake `?us###`?|no fake `?im###`?' 'spec-refinement forbids fabricated story/implementation links'
assert_file_contains "$SPEC_REFINEMENT" 'akm read' 'spec-refinement names akm for AKM artifact access'

assert_file_contains "$SPEC_READY" 'feature-add|proposed `?ft###`?' 'spec-ready handles feature-add specs'
assert_file_contains "$SPEC_READY" 'story-backed.*source `?us###`?.*consumed `?im###`?|source `?us###`?.*consumed `?im###`?.*story-backed' 'spec-ready keeps story-backed epic context explicit'
assert_file_contains "$SPEC_READY" 'Do not fabricate|no fake `?us###`?|no fake `?im###`?' 'spec-ready forbids fabricated story/implementation links'

assert_file_contains "$SPEC_REFINEMENT_EVALS" 'feature-add.*no `?us###`?.*no `?im###`?|no `?us###`?.*no `?im###`?.*feature-add' 'spec-refinement evals include feature-add no-story/no-implementation fixture'
assert_file_contains "$SPEC_REFINEMENT_GRADER" 'feature_only|feature-only|feature_add|feature-add' 'spec-refinement grader validates feature-only behavior'
assert_file_contains "$SPEC_REFINEMENT_GRADER" 'akm read' 'spec-refinement grader asserts akm access instruction'
assert_file_contains "$SPEC_REFINEMENT_GRADER" 'generic.*SRE PASS|SRE PASS.*generic' 'spec-refinement grader rejects generic SRE pass assertion'

printf 'PASS: runtime adapter contract static validation\n'
