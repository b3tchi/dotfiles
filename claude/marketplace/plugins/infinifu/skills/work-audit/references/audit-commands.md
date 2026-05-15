# Audit Commands

**Load this reference when:** you are running the automated checks in Step 2 of the review. Each section has detection patterns and a "what to do if found" note.

## Code completeness

```bash
# TODOs / FIXMEs without issue numbers
rg -i "todo|fixme" src/ tests/ || echo "✅ None"

# Stub implementations
rg "unimplemented!|todo!|unreachable!|panic!\(\"not implemented" src/ || echo "✅ None"

# Unsafe patterns in production code
rg "\.unwrap\(\)|\.expect\(" src/ | grep -v "/tests/" || echo "✅ None"

# Ignored or skipped tests
rg "#\[ignore\]|#\[skip\]|\.skip\(\)" tests/ src/ || echo "✅ None"
```

If any of these return hits, the implementation is not done. A TODO without an issue number is a promise to forget. A stub means the task is mislabeled as complete.

## Dead code and refactoring remnants

A refactor that leaves the old implementation in place is incomplete. The canonical implementation is the new one; anything else is dead code.

```bash
# Fallback or legacy naming
rg -i "fallback|legacy|old_|_old|deprecated|obsolete" src/ || echo "✅ None"

# Feature flags that enable old code paths
rg -i "if.*use.*old|if.*legacy|if.*fallback|ENABLE_OLD|USE_LEGACY|FALLBACK_TO" src/ || echo "✅ None"

# "was:" or "previously:" comments describing removed behavior
rg -i "was:|previously:|used to|before refactor" src/ || echo "✅ None"

# Rust — dead code warnings
cargo build 2>&1 | grep -E "warning.*never used|warning.*dead_code" || echo "✅ None"

# TypeScript/JS — unused exports via ESLint
npx eslint --rule 'no-unused-vars: error' src/ 2>/dev/null || echo "Check manually"

# Swift — unused variables
swiftlint lint --reporter json 2>/dev/null | jq '.[] | select(.rule_id == "unused")' || echo "Check manually"

# Python — vulture
vulture src/ --min-confidence 80 2>/dev/null || echo "vulture not installed; check manually"

# Orphaned tests (reference removed code)
git diff main...HEAD --name-only | grep -E "(test|spec)" || echo "No test files changed"

# Deprecation markers (should be REMOVED, not marked)
rg "@deprecated|#\[deprecated\]|// deprecated|DEPRECATED|@Deprecated" src/ || echo "✅ None"

# Backwards compatibility shims (unless external API)
rg -i "backward.*compat|legacy.*support|shim|polyfill" src/ || echo "✅ None"
```

### What to do if a hit appears

| Finding | Action |
|---------|--------|
| Fallback code | Delete. Why is the old implementation still there? |
| Unused functions | Delete. If nobody calls it, it's not part of the system. |
| Orphaned tests | If the tested code is gone, delete the test. |
| Deprecation markers | Remove the code now or file a bd issue with a removal date. |
| Backwards-compat shims | Keep only if this is an external API. Internal code doesn't need compat. |

Dead code after refactoring = incomplete refactoring = a gap.

## Anti-patterns search

Replace `[pattern]` with each prohibited item from the bd task's anti-patterns section and run:

```bash
rg "[pattern]" src/
```

Examples:

```bash
rg "\.unwrap\(\)" src/               # if task prohibits unwrap
rg "TODO" src/                        # if task prohibits untracked TODOs
rg "\.skip\(\)" tests/                # if task prohibits skipped tests
rg "console\.log" src/                # if task mandates structured logger
```

For every match, record the file and line in the findings table.

## Quality gates

Dispatch via the `test-runner` agent so verbose output stays out of your context:

```
Dispatch test-runner: "Run: cargo test"
Dispatch test-runner: "Run: cargo fmt --check"
Dispatch test-runner: "Run: cargo clippy -- -D warnings"
Dispatch test-runner: "Run: .git/hooks/pre-commit"
```

Adapt the commands to the language (npm test / npm run lint, pytest / ruff, go test / golangci-lint, etc.).

A clean pre-commit is the minimum bar. If the hook fails, the task isn't ready — no amount of "it works locally" overrides the gate.
