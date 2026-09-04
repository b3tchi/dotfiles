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

printf 'PASS: runtime adapter contract static validation\n'
