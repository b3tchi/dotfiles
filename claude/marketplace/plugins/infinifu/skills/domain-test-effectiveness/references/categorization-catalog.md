# Test Categorization Catalog (RED / YELLOW / GREEN)

**Load this reference when:** you are applying Phase 3 of the audit — categorizing individual tests. This is the detailed taxonomy with code examples for each pattern.

## The baseline

**Default to skeptical:** a test is RED or YELLOW until you have concrete evidence it's GREEN. Read production code *before* deciding. GREEN is the exception.

---

## RED flags — must remove or replace

RED tests provide false confidence. They pass regardless of whether production code is correct.

### 1. Tautological tests (pass by definition)

```typescript
// ❌ RED — verifies non-optional return is not null (always passes)
test('builder returns value', () => {
  const result = new Builder().build();
  expect(result).not.toBeNull(); // return type guarantees this
});

// ❌ RED — verifies enum has cases (the compiler already checks this)
test('status enum has values', () => {
  expect(Object.values(Status).length).toBeGreaterThan(0);
});

// ❌ RED — duplicates the implementation
test('add returns sum', () => {
  expect(add(2, 3)).toBe(2 + 3); // testing 2+3 == 2+3
});
```

**Detection:**

```bash
# !=null on non-optional types
rg "expect\(.*\)\.not\.toBeNull|assertNotNull|!= nil" tests/

# enum existence checks
rg "Object\.values.*length|cases\.count" tests/

# tests with a single assertion
rg -l "expect\(" tests/ | xargs -I {} sh -c 'grep -c "expect" {} | grep -q "^1$" && echo {}'
```

### 2. Mock-testing tests (test the mock, not production)

```typescript
// ❌ RED — only verifies mock was called
test('service fetches data', () => {
  const mockApi = { fetch: jest.fn().mockResolvedValue({ data: [] }) };
  const service = new Service(mockApi);
  service.getData();
  expect(mockApi.fetch).toHaveBeenCalled();
});

// ❌ RED — mock determines the outcome
test('processor handles data', () => {
  const mockParser = { parse: jest.fn().mockReturnValue({ valid: true }) };
  const result = processor.process(mockParser);
  expect(result.valid).toBe(true); // just echoing the mock
});
```

**Detection:**

```bash
rg "toHaveBeenCalled|verify\(mock|\.called" tests/
rg -c "mock|Mock|jest\.fn|stub" tests/ | sort -t: -k2 -nr | head -20
```

### 3. Line hitters (execute without asserting)

```typescript
// ❌ RED — no assertion, just verifies no crash
test('processor runs', () => {
  const processor = new Processor();
  processor.run();
});

// ❌ RED — assertion is trivial
test('config loads', () => {
  const config = loadConfig();
  expect(config).toBeDefined(); // doesn't verify correct values
});
```

**Detection:**

```bash
rg -l "test\(|it\(" tests/ | while read f; do
  assertions=$(rg -c "expect|assert" "$f" 2>/dev/null || echo 0)
  tests=$(rg -c "test\(|it\(" "$f" 2>/dev/null || echo 1)
  ratio=$((assertions / tests))
  [ "$ratio" -lt 2 ] && echo "$f: low assertion ratio ($assertions assertions, $tests tests)"
done
```

### 4. Evergreen / liar tests (always pass)

```typescript
// ❌ RED — catches and ignores exceptions
test('parser handles input', () => {
  try {
    parser.parse(input);
    expect(true).toBe(true); // always passes
  } catch (e) {
    // swallowed
  }
});

// ❌ RED — setup bypasses code under test
test('validator validates', () => {
  const validator = new Validator({ skipValidation: true });
  expect(validator.validate(badInput)).toBe(true);
});
```

---

## YELLOW flags — must strengthen

YELLOW tests exercise production code but too weakly to catch the bugs they should.

### 1. Happy-path-only

```typescript
// ⚠️ YELLOW — only tests valid input
test('parse valid json', () => {
  const result = parse('{"name": "test"}');
  expect(result.name).toBe('test');
});
// Missing: empty string, malformed JSON, deeply nested, unicode, huge payload
```

### 2. Weak assertions

```typescript
// ⚠️ YELLOW — assertion is too loose
test('fetch returns data', async () => {
  const result = await fetch('/api/users');
  expect(result).not.toBeNull();
  expect(result.length).toBeGreaterThan(0); // should verify exact count or specific items
});
```

### 3. Partial coverage

```typescript
// ⚠️ YELLOW — tests success, never failure
test('create user succeeds', () => {
  const user = createUser({ name: 'test', email: 'test@example.com' });
  expect(user.id).toBeDefined();
});
// Missing: duplicate email, invalid email, missing fields, database error
```

---

## GREEN flags — exceptional quality required

GREEN is the exception, not the rule. A test is GREEN **only if all of these hold:**

1. Exercises actual production code (not a mock, not a test utility, not a copy of logic)
2. Precise assertions (exact values, not `!= nil` or `> 0`)
3. Would fail if production breaks — you can name the specific bug it would catch
4. Tests behavior, not implementation (won't break on valid refactoring)

**Before marking anything GREEN, state out loud:**

- "This test exercises *[specific production code path]*."
- "It would catch *[specific bug]* because *[reason]*."
- "The assertion verifies *[exact production behavior]*, not a test fixture."

If you cannot fill in those blanks, the test is YELLOW at best.

### Behavior verification

```typescript
// ✅ GREEN — verifies specific behavior with exact values from production
test('calculateTotal applies discount correctly', () => {
  const cart = new Cart([{ price: 100, quantity: 2 }]);
  cart.applyDiscount('SAVE20');
  expect(cart.total).toBe(160); // 200 - 20% = 160
});
```

### Edge-case coverage

```typescript
// ✅ GREEN — tests boundary conditions in production code
test('username rejects empty string', () => {
  expect(() => new User({ username: '' })).toThrow(ValidationError);
});

test('username handles unicode', () => {
  const user = new User({ username: '日本語ユーザー' });
  expect(user.username).toBe('日本語ユーザー');
});
```

### Error-path testing

```typescript
// ✅ GREEN — verifies error handling in production code
test('fetch returns specific error on 404', async () => {
  mockServer.get('/api/user/999').reply(404); // external mock is fine
  await expect(fetchUser(999)).rejects.toThrow(UserNotFoundError);
});
```

**Caution:** A test that mocks an *external* dependency (API, database) can still be GREEN if it exercises production logic. A test that mocks the *code under test* is RED.

---

## Self-review before finalizing

For each GREEN:

- Did I read the production code this test exercises?
- Does the test call production code or a test utility/mock?
- Can I name the specific bug this test would catch?
- If production code broke, would this test definitely fail?
- Am I being generous because the test "looks reasonable"?

For each YELLOW:

- Should this actually be RED? Is there *any* bug-catching value?
- Is the weakness fundamental (tests a mock) or fixable (weak assertion)?
- If I changed this to RED, would I lose any bug-catching ability?

**Self-challenge questions:**

- *"If a junior engineer showed me this test, would I accept it as GREEN?"*
- *"Am I marking this GREEN because I want to be done, or because it's genuinely good?"*
- *"Could I defend this GREEN classification to a senior SRE?"*

If any doubt about a GREEN → downgrade to YELLOW. If any doubt about a YELLOW → consider RED.

**A false GREEN is worse than a false YELLOW.** When in doubt, be harsher.
