---
name: domain-test-anti-patterns
description: Use when writing or changing tests, adding mocks - prevents testing mock behavior, production pollution with test-only methods, and mocking without understanding dependencies
---

<skill_overview>
Tests must verify real behavior, not mock behavior; mocks are tools to isolate, not things to test.
</skill_overview>

<rigidity_level>
LOW FREEDOM — the three laws below are treated as absolute because violating any one of them produces tests that feel like coverage but catch nothing. The rule is rigid; the *reason* is that each violation creates false confidence, which is worse than no test. Use the gate questions before you mock or add production helpers — they're the fast check.
</rigidity_level>

<quick_reference>
## The 3 Iron Laws

1. **NEVER test mock behavior** → Test real component behavior
2. **NEVER add test-only methods to production** → Use test utilities instead
3. **NEVER mock without understanding** → Know dependencies before mocking

## Gate Functions (Use Before Action)

**Before asserting on any mock:**
- Ask: "Am I testing real behavior or mock existence?"
- If mock existence → STOP, delete assertion

**Before adding method to production:**
- Ask: "Is this only used by tests?"
- If yes → STOP, put in test utilities

**Before mocking:**
- Ask: "What side effects does real method have?"
- Ask: "Does test depend on those side effects?"
- If depends → Mock lower level, not this method
</quick_reference>

<when_to_use>
- Writing new tests
- Adding mocks to tests
- Tempted to add method only tests will use
- Test failing and considering mocking something
- Unsure whether to mock a dependency
- Test setup becoming complex with mocks

**Critical moment:** Before you add a mock or test-only method, use this skill's gate functions.
</when_to_use>

<the_iron_laws>
## Law 1: Never Test Mock Behavior

**Anti-pattern:**
```rust
// ❌ BAD: Testing that mock exists
#[test]
fn test_processes_request() {
    let mock_service = MockApiService::new();
    let handler = RequestHandler::new(Box::new(mock_service));

    // Testing mock existence, not behavior
    assert!(handler.service().is_mock());
}
```

**Why wrong:** Verifies mock works, not that code works.

**Fix:**
```rust
// ✅ GOOD: Test real behavior
#[test]
fn test_processes_request() {
    let service = TestApiService::new();  // Real implementation or full fake
    let handler = RequestHandler::new(Box::new(service));

    let result = handler.process_request("data");
    assert_eq!(result.status, StatusCode::OK);
}
```

---

## Law 2: Never Add Test-Only Methods to Production

**Anti-pattern:**
```rust
// ❌ BAD: reset() only used in tests
pub struct Connection {
    pool: Arc<ConnectionPool>,
}

impl Connection {
    pub fn reset(&mut self) {  // Looks like production API!
        self.pool.clear_all();
    }
}

// In tests
#[test]
fn test_something() {
    let mut conn = Connection::new();
    conn.reset();  // Test-only method
}
```

**Why wrong:**
- Production code polluted with test-only methods
- Dangerous if accidentally called in production
- Confuses object lifecycle with entity lifecycle

**Fix:**
```rust
// ✅ GOOD: Test utilities handle cleanup
// Connection has no reset()

// In tests/test_utils.rs
pub fn cleanup_connection(conn: &Connection) {
    if let Some(pool) = conn.get_pool() {
        pool.clear_test_data();
    }
}

// In tests
#[test]
fn test_something() {
    let conn = Connection::new();
    cleanup_connection(&conn);
}
```

---

## Law 3: Never Mock Without Understanding

**Anti-pattern:**
```rust
// ❌ BAD: Mock breaks test logic
#[test]
fn test_detects_duplicate_server() {
    // Mock prevents config write that test depends on!
    let mut config_manager = MockConfigManager::new();
    config_manager.expect_add_server()
        .returning(|_| Ok(()));  // No actual config write!

    config_manager.add_server(&config).unwrap();
    config_manager.add_server(&config).unwrap();  // Should fail - but won't!
}
```

**Why wrong:** Mocked method had side effect test depended on (writing config).

**Fix:**
```rust
// ✅ GOOD: Mock at correct level
#[test]
fn test_detects_duplicate_server() {
    // Mock the slow part, preserve behavior test needs
    let server_manager = MockServerManager::new();  // Just mock slow server startup
    let config_manager = ConfigManager::new_with_manager(server_manager);

    config_manager.add_server(&config).unwrap();  // Config written
    let result = config_manager.add_server(&config);  // Duplicate detected ✓
    assert!(result.is_err());
}
```
</the_iron_laws>

<gate_functions>
## Gate Function 1: Before Asserting on Mock

```
BEFORE any assertion that checks mock elements:

1. Ask: "Am I testing real component behavior or just mock existence?"

2. If testing mock existence:
   STOP - Delete the assertion or unmock the component

3. Test real behavior instead
```

**Examples of mock existence testing (all wrong):**
- `assert!(handler.service().is_mock())`
- `XCTAssertTrue(manager.delegate is MockDelegate)`
- `expect(component.database).toBe(mockDb)`

---

## Gate Function 2: Before Adding Method to Production

```
BEFORE adding any method to production class:

1. Ask: "Is this only used by tests?"

2. If yes:
   STOP - Don't add it
   Put it in test utilities instead

3. Ask: "Does this class own this resource's lifecycle?"

4. If no:
   STOP - Wrong class for this method
```

**Red flags:**
- Method named `reset()`, `clear()`, `cleanup()` in production class
- Method only has `#[cfg(test)]` callers
- Method added "for testing purposes"

---

## Gate Function 3: Before Mocking

```
BEFORE mocking any method:

STOP - Don't mock yet

1. Ask: "What side effects does the real method have?"
2. Ask: "Does this test depend on any of those side effects?"
3. Ask: "Do I fully understand what this test needs?"

If depends on side effects:
  → Mock at lower level (the actual slow/external operation)
  → OR use test doubles that preserve necessary behavior
  → NOT the high-level method the test depends on

If unsure what test depends on:
  → Run test with real implementation FIRST
  → Observe what actually needs to happen
  → THEN add minimal mocking at the right level
```

**Red flags:**
- "I'll mock this to be safe"
- "This might be slow, better mock it"
- Mocking without understanding dependency chain
</gate_functions>

<extended_references>
Worked examples and additional patterns live in `references/`, loaded on demand rather than inline in SKILL.md:

- **`references/examples.md`** — Three full worked examples, one per Iron Law, showing a realistic broken test, why it fails, the gate-function diagnosis, the fix, and what you gain. Read this when a specific pattern feels abstract or you want to see the failure mode concretely.
- **`references/additional-anti-patterns.md`** — Two more patterns that surface in review often enough to call out: incomplete mocks (missing fields → runtime panic) and over-complex mocks (signal that the test is at the wrong layer). Read this when reviewing a mock setup that feels heavy.
</extended_references>

<tdd_prevention>
## TDD Prevents These Anti-Patterns

**Why TDD helps:**

1. **Write test first** → Forces thinking about what you're actually testing
2. **Watch it fail** → Confirms test tests real behavior, not mocks
3. **Minimal implementation** → No test-only methods creep in
4. **Real dependencies** → See what test needs before mocking

**If you're testing mock behavior, you violated TDD** - you added mocks without watching test fail against real code first.

Prerequisite: `infinifu:domain-tdd`. This skill extends the RED-GREEN-REFACTOR discipline to the mock/test-double boundary — if the TDD cycle itself is unfamiliar, start there.
</tdd_prevention>

<critical_rules>
## Rules That Have No Exceptions

1. **Never test mock behavior** → Test real component behavior always
2. **Never add test-only methods to production** → Pollutes production code
3. **Never mock without understanding** → Must know dependencies and side effects
4. **Use gate functions before action** → Before asserting, adding methods, or mocking
5. **Follow TDD** → Write test first, watch fail, prevents testing mocks

## Common Excuses

All of these mean: **STOP. Apply the gate function.**

- "Just checking the mock is wired up" (Testing mock, not behavior)
- "Need reset() for test cleanup" (Test-only method, use test utilities)
- "I'll mock this to be safe" (Don't understand dependencies)
- "Mock setup is complex but necessary" (Probably over-mocking)
- "This will speed up tests" (Might break test logic)
</critical_rules>

<verification_checklist>
Before claiming tests are correct:

- [ ] No assertions on mock elements (no `is_mock()`, `is MockType`, etc.)
- [ ] No test-only methods in production classes
- [ ] All mocks preserve side effects test depends on
- [ ] Mock at lowest level needed (mock slow I/O, not business logic)
- [ ] Understand why each mock is necessary
- [ ] Mock structure matches real API completely
- [ ] Test logic shorter/equal to mock setup (not longer)
- [ ] Followed TDD (test failed with real code before mocking)

**Can't check all boxes?** Apply gate functions and refactor.
</verification_checklist>

<integration>
**This skill requires:**
- infinifu:domain-tdd (prevents these anti-patterns)
- Understanding of mocking vs. faking vs. stubbing

**This skill is called by:**
- When writing tests
- When adding mocks
- When test setup becoming complex
- infinifu:domain-tdd (use gate functions during RED phase)

**Red flags triggering this skill:**
- Assertion checks for `*-mock` test IDs
- Methods only called in test files
- Mock setup >50% of test
- Test fails when you remove mock
- Can't explain why mock needed
</integration>

<resources>
**When stuck:**
- Mock too complex → Consider integration test with real components
- Unsure what to mock → Run with real implementation first, observe
- Test failing mysteriously → Check if mock breaks test logic (use Gate Function 3)
- Production polluted → Move all test helpers to test_utils
</resources>
