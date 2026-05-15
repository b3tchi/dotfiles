# Findings Template

**Load this reference when:** you are writing up the results of a per-task review in Step 2, or compiling the overall decision in Step 3.

## Per-task findings

```markdown
### Task: bd-N — [Task name]

#### Evidence-Based Findings

| Criterion | Status | Confidence | Evidence |
|-----------|--------|------------|----------|
| All tests pass | ✅ Met | 1.0 | `cargo test`: 127 passed, 0 failed |
| Pre-commit passes | ❌ Not met | 1.0 | `cargo clippy`: 3 warnings |
| No unwrap in production | ❌ Not met | 1.0 | `rg "\.unwrap()"`: src/auth/jwt.ts:45 |

Any finding below 0.8 confidence must be investigated further or marked UNCERTAIN.

#### File Evidence

| File | Line | What verified | Confidence |
|------|------|---------------|------------|
| src/auth/jwt.ts | 45 | unwrap violation | 1.0 |
| src/auth/jwt.ts | 12-30 | token generation logic reviewed | 0.9 |

#### Automated Checks

- TODOs: ✅ None
- Stubs: ✅ None
- Unsafe patterns: ❌ Found `.unwrap()` at src/auth/jwt.ts:45
- Ignored tests: ✅ None

#### Dead Code Audit

| Category | Pattern | Found | Location | Action |
|----------|---------|-------|----------|--------|
| Fallback code | `legacy\|old_\|fallback` | 0 | — | ✅ None |
| Unused functions | compiler warnings | 0 | — | ✅ None |
| Deprecation markers | `@deprecated` | 0 | — | ✅ None |
| Orphaned tests | tests for removed code | 0 | — | ✅ None |
| Backwards-compat shims | `shim\|polyfill` | 0 | — | ✅ None |

**Verdict:** ✅ No dead code / ❌ Dead code found — refactoring incomplete

#### Quality Gates

- Tests: ✅ Pass (127 tests)
- Formatting: ✅ Pass
- Linting: ❌ 3 warnings
- Pre-commit: ❌ Fails due to linting

#### Files Reviewed

- src/auth/jwt.ts: ⚠️ Contains `.unwrap()` at line 45
- tests/auth/jwt_test.rs: ✅ Complete

#### Code Quality

- Error handling: ⚠️ Uses unwrap instead of proper error propagation
- Safety: ✅ Good
- Clarity: ✅ Good
- Testing: see test quality audit below

#### Test Quality Audit (new/modified tests)

| Test | Bug it catches | Verdict |
|------|----------------|---------|
| test_valid_token_accepted | Missing validation | ✅ Keep |
| test_expired_token_rejected | Expiration bypass | ✅ Keep |
| test_jwt_struct_exists | Nothing (tautological) | ❌ Remove |
| test_encode_decode | Encoding bug, but happy path only | ⚠️ Add edge cases |

Tautological tests found: 1. Weak tests found: 1.

#### Anti-Patterns

- "No unwrap in production": ❌ Violated at src/auth/jwt.ts:45

#### Issues

**Critical:**
1. `.unwrap()` at jwt.ts:45 — violates anti-pattern, must use proper error handling
2. Tautological test `test_jwt_struct_exists` must be removed

**Important:**
3. 3 clippy warnings block the pre-commit hook
4. `test_encode_decode` needs edge cases (empty, unicode, max length)
```

## Overall decision — approved

```markdown
## Implementation Review: APPROVED ✅

Reviewed bd-1 ([Epic name]) against implementation.

### Tasks reviewed
- bd-2: [Task name] ✅
- bd-3: [Task name] ✅
- bd-4: [Task name] ✅

### Verification summary
- All success criteria verified with evidence
- No anti-patterns detected
- All key considerations addressed in code
- All files implemented per spec

### Evidence
- Tests: 127 passed, 0 failures (2.3s)
- Linting: no warnings
- Pre-commit: pass
- Code review: production-ready

Ready to proceed to `infinifu:work-merge`.
```

## Overall decision — gaps found

```markdown
## Implementation Review: GAPS FOUND ❌

Reviewed bd-1 ([Epic name]) against implementation.

### Tasks with gaps

#### bd-3: [Task name]
**Gaps:**
- ❌ Success criterion not met: "Pre-commit hooks pass"
  - Evidence: `cargo clippy` shows 3 warnings
- ❌ Anti-pattern violation: `.unwrap()` at src/auth/jwt.ts:45
- ⚠️ Key consideration not addressed: "Empty payload validation"
  - No check for empty payload in `generateToken()`

#### bd-4: [Task name]
**Gaps:**
- ❌ Success criterion not met: "All tests passing"
  - Evidence: `test_verify_expired_token` failing

### Cannot proceed
Implementation does not match spec. Fix gaps before completing.
```

## After a gaps-found decision

Do **not** invoke `infinifu:work-merge`. Either:

1. Fix the gaps and re-run this review, or
2. Discuss with your human partner — some gaps may be out of scope for this epic and belong in a follow-up bd issue.

The spec is the contract. Partial fulfilment is not fulfilment.
