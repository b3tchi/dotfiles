# Additional Anti-Patterns

Beyond the 3 Iron Laws, two more patterns surface in review often enough to call out explicitly.

## Anti-Pattern 4 — Incomplete Mocks

**Problem:** Mock only the fields you think you need, omit others.

```rust
// ❌ BAD: Partial mock
struct MockResponse {
    status: String,
    data: UserData,
    // Missing: metadata that downstream code uses
}

impl ApiResponse for MockResponse {
    fn metadata(&self) -> &Metadata {
        panic!("metadata not implemented!")  // Breaks at runtime!
    }
}
```

**Fix:** Mirror the real API completely.

```rust
// ✅ GOOD: Complete mock
struct MockResponse {
    status: String,
    data: UserData,
    metadata: Metadata,  // All fields real API returns
}
```

**Gate function:**

```
BEFORE creating mock responses:
  1. Examine actual API response structure
  2. Include ALL fields the system might consume
  3. Verify mock matches real schema completely
```

## Anti-Pattern 5 — Over-Complex Mocks

**Warning signs:**

- Mock setup longer than the test logic
- Mocking everything to make the test pass
- Test breaks whenever the mock changes

**Consider:** An integration test with real components is often simpler than a deeply-mocked unit test. The complexity of the mock is a signal that the test is at the wrong layer.
