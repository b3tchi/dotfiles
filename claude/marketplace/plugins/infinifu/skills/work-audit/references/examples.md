# Worked Examples

**Load this reference when:** you want to see the review applied to concrete failure modes. Each example shows a shortcut reviewers take, why it misses bugs, and what the rigorous pass produces instead.

## Example 1 — Reviewing the diff instead of the file

### The shortcut

```bash
git diff main...HEAD
```

The diff shows:

```diff
+ function generateToken(payload) {
+   return jwt.sign(payload, secret);
+ }
```

Approval: *"Looks good, token generation implemented ✅"*

### Why it misses bugs

Diffs show *changes*, not *context*. The full file reveals:

```javascript
function generateToken(payload) {
  // Missing: empty payload check (key consideration from bd task)
  // Missing: error handling if jwt.sign fails
  return jwt.sign(payload, secret);
}
```

The task's "Key Considerations" said empty payloads must be rejected. The diff didn't include any validation to reject, and the reviewer didn't notice because they never saw surrounding context. Empty payload in production → untyped JWT → downstream crashes.

### The rigorous pass

```bash
git diff main...HEAD -- src/auth/jwt.ts
# … plus …
Read tool: src/auth/jwt.ts
```

Reading the full file surfaces both gaps:

- Empty payload validation missing (key consideration not addressed)
- `jwt.sign` can throw; error handling missing

Both go in the findings table with file and line, both block approval.

---

## Example 2 — "Tests pass, so it's done"

### The shortcut

```bash
cargo test
# 127 tests passed ✅
```

Approval: *"Tests pass, implementation complete ✅"*

### Why it misses bugs

Tests passing satisfies one success criterion. The bd task had five:

1. All tests pass ✅
2. Pre-commit passes — *never checked*
3. No unwrap in production — *never checked*
4. Unicode handling tested — *never verified*
5. Rate limiting implemented — *never verified*

When the PR hits CI, criterion 2 fails (clippy warnings block pre-commit), criterion 3 violation ships a crash risk, criterion 4 means a known encoding bug class is unaddressed. "1 of 5 criteria verified" isn't done.

### The rigorous pass

Walk every criterion with an explicit command or code read:

```markdown
1. "All tests pass"       ✅ — cargo test: 127 passed
2. "Pre-commit passes"    ❌ — cargo clippy: 3 warnings
3. "No unwrap in prod"    ❌ — rg "\.unwrap\(\)" src/: src/auth/jwt.ts:45
4. "Unicode handling"     ⚠️ — rg "unicode" tests/: no matches, verify code
5. "Rate limiting"        ⚠️ — read src/api/middleware.ts

Result: 1/5 verified. GAPS EXIST.
```

Decision: gaps found, do not proceed.

---

## Example 3 — Rationalizing rigor away on "simple" tasks

### The shortcut

bd task: *"Add logging to error paths."*

Reviewer thinks: *"Simple task, just added console.log. Skip the full process."*

Approval: *"Logging added ✅"*

### Why it misses bugs

"Simple" tasks hide the same failure modes as complex ones — and because the review is skipped, they hit production:

- `console.log` used instead of the proper logger (anti-pattern)
- Logging added to 2 of 5 error paths (incomplete)
- No test verifies logs actually output (success criterion unmet)
- Logs contain the password field (security issue)

### The rigorous pass

```bash
# Automated checks
rg "console\.log" src/
# Found at error-handler.ts:12, 15 — anti-pattern violation

bd show bd-5
# Criteria: all error paths logged; no sensitive data; test verifies output

grep -n "throw new Error" src/
# 5 throw sites; only 2 have logging — incomplete

Read tool: src/error-handler.ts
# Logs contain password field — security issue

rg "test.*log" tests/
# No matches — missing test
```

Decision: four distinct gaps found in a "simple" task. Simple is not exempt.

---

## Example 4 — High coverage, but tautological tests

### The shortcut

```
cargo test
# 45 tests passed ✅
# Coverage: 92% ✅
```

Approval: *"Tests pass with 92% coverage, implementation complete ✅"*

### Why it misses bugs

Coverage counts *execution*, not *meaningful assertions*. Read the tests:

- `expect(validator != nil)` — always passes; doesn't test validation
- `expect(lock.acquire())` — tests a mock, not thread safety
- `expect(encoded.count > 0)` — tests non-empty, not correctness

Later in production: validation bypassed, race condition corrupts data, encoding corruption on non-ASCII input.

### The rigorous pass

```bash
git diff main...HEAD --name-only | grep test
Read tool: tests/validator_test.swift
```

Audit each test:

| Test | Assertion | Bug caught? | Verdict |
|------|-----------|-------------|---------|
| testValidatorExists | `!= nil` | ❌ None (compiler checks) | ❌ Remove |
| testValidInput | `isValid == true` | ⚠️ Happy path only | ⚠️ Strengthen |
| testEmptyInputFails | `isValid == false` | ✅ Missing validation | ✅ Keep |
| testLockAcquired | `mock.acquireCalled` | ❌ Tests mock | ❌ Replace |
| testConcurrentAccess | `count == expected` | ✅ Race condition | ✅ Keep |
| testEncodeNotNil | `!= nil` | ❌ Type guarantees this | ❌ Remove |
| testUnicodeRoundtrip | `decoded == original` | ✅ Encoding corruption | ✅ Keep |

Three tautological tests removed, one weak test strengthened, three genuine tests kept. Coverage goes down on paper; real effectiveness goes up.

For the full categorization framework, invoke `infinifu:domain-test-effectiveness`.

---

## Example 5 — Refactor that didn't delete the old implementation

### The shortcut

After refactoring the auth system:

```javascript
function authenticateV2(token) { ... }   // new implementation
function authenticate(token) { ... }      // old, still there
function authenticateLegacy(token) { ... } // even older
```

```javascript
// config
const USE_LEGACY_AUTH = process.env.LEGACY_AUTH ?? true;
```

Claim: *"Refactoring complete."*

### Why it misses bugs

Three implementations, a feature flag defaulting to the oldest, tests possibly still pointing at the old functions. Technical debt increased rather than decreased. The refactor *added* code instead of *replacing* it.

### The rigorous pass

```bash
rg -i "legacy|old_|fallback" src/
# Found: authenticateLegacy, USE_LEGACY_AUTH

rg "authenticate\(" src/ --type ts
# authenticate: 0 callers
# authenticateLegacy: 0 callers
# authenticateV2: 15 callers
```

Dead code audit:

| Category | Pattern | Found | Location | Action |
|----------|---------|-------|----------|--------|
| Fallback code | `legacy\|fallback` | 2 | auth.ts:45, 89 | Delete |
| Unused functions | no callers | 2 | `authenticate()`, `authenticateLegacy()` | Delete |
| Feature flags | `USE_LEGACY` | 1 | config.ts:12 | Delete |

Required actions:

1. Delete `authenticate()` — replaced by `authenticateV2()`
2. Delete `authenticateLegacy()` — obsolete
3. Delete the `USE_LEGACY_AUTH` flag — no longer needed
4. Rename `authenticateV2()` back to `authenticate()` (cleaner API)
5. Update or delete tests for the removed functions

Decision: gaps found. Version control remembers the old implementation; the codebase shouldn't.
