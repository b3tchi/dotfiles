# Worked Examples

**Load this reference when:** you want to see the audit applied end-to-end on realistic situations.

## Example 1 — High coverage, production bugs keep appearing

### Setup

```
Coverage: 92%
Tests: 245 passing

Yet production issues:
- Auth bypass via empty password
- Data corruption on concurrent updates
- Crash on unicode usernames
```

### What's happening

Coverage measures *execution*, not *assertion quality*. High coverage with persistent production bugs is the signature of tautological tests, weak assertions, and missing corner cases. The confidence is the problem — the team trusted a number that didn't mean what they thought.

### Audit walkthrough

**Phase 1 — inventory:**

```bash
fd -e test.ts src/
# Found: auth.test.ts, user.test.ts, data.test.ts
```

**Phase 3 — categorize (after reading production code):**

```markdown
### auth.test.ts
| Test            | Category | Problem                                    |
|-----------------|----------|--------------------------------------------|
| testAuthWorks   | RED      | Only checks `!= null`                      |
| testLoginFlow   | YELLOW   | Happy path only, no empty password         |
| testTokenExpiry | GREEN    | Verifies exact error                       |

### data.test.ts
| Test                | Category | Problem                     |
|---------------------|----------|-----------------------------|
| testDataSaves       | RED      | No assertion, just calls save() |
| testConcurrentWrites| MISSING  | Not tested at all            |
```

**Phase 5 — corner-case gaps:**

```markdown
### auth module (P0)
Missing:
- [ ] test_empty_password_rejected
- [ ] test_unicode_username_preserved
- [ ] test_concurrent_login_safe
```

**Phase 7 — plan:**

```markdown
### Immediate
- Remove testAuthWorks (tautological)
- Remove testDataSaves (line hitter)

### This sprint
- Add test_empty_password_rejected
- Add test_concurrent_writes_safe
- Strengthen testLoginFlow with edge cases
```

### Outcome

The three production bugs were all caused by tests that existed but didn't catch them — the empty password wasn't in any test case, the concurrent update case wasn't tested at all, and unicode wasn't covered in user creation. Removing the RED tests exposed the coverage gap honestly; adding the corner cases prevented the next round of bugs.

---

## Example 2 — Mock-heavy suite that breaks on every refactor

### Setup

Every refactor breaks 50+ tests, but bugs slip through to production anyway.

```typescript
test('service processes data', () => {
  const mockDb = jest.fn().mockReturnValue({ data: [] });
  const mockCache = jest.fn().mockReturnValue(null);
  const mockLogger = jest.fn();
  const mockValidator = jest.fn().mockReturnValue(true);

  const service = new Service(mockDb, mockCache, mockLogger, mockValidator);
  service.process({ id: 1 });

  expect(mockDb).toHaveBeenCalled();
  expect(mockValidator).toHaveBeenCalled();
});
```

### What's happening

These tests verify *mock wiring*, not production behavior. They're coupled to implementation details (which mocks get called in what order), so they break when the implementation changes — even when the behavior is correct. And because the mocks determine the outcome, no real bug can reach an assertion.

This is "mocks mocking mocks" — the worst of both worlds. High maintenance cost, zero bug-catching value.

### Audit walkthrough

**Categorize as RED (mock-testing):**

```markdown
### service.test.ts
| Test                | Category | Problem                    | Action                     |
|---------------------|----------|----------------------------|----------------------------|
| testServiceProcesses| RED      | Only verifies mocks called | Replace with integration   |
| testServiceValidates| RED      | Mock determines outcome    | Test the real validator    |
| testServiceCaches   | RED      | Tests the mock cache       | Use real cache + test data |
```

### Replacement strategy

```typescript
// ❌ Before — tests mock wiring
test('service validates', () => {
  const mockValidator = jest.fn().mockReturnValue(true);
  const service = new Service(mockValidator);
  expect(mockValidator).toHaveBeenCalled();
});

// ✅ After — tests real behavior
test('service rejects invalid data', () => {
  const service = new Service(new RealValidator());
  const result = service.process({ id: -1 }); // invalid id
  expect(result.error).toBe('INVALID_ID');
});

test('service accepts valid data', () => {
  const service = new Service(new RealValidator());
  const result = service.process({ id: 1, name: 'test' });
  expect(result.success).toBe(true);
  expect(result.data.name).toBe('test');
});
```

### Outcome

Tests now verify behavior, not implementation. Refactoring stops breaking tests unless behavior actually changed. Real bugs get caught because real validation logic runs. The suite shrinks and strengthens at the same time.
