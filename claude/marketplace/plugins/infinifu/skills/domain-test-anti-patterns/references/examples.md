# Extended Examples — domain-test-anti-patterns

Three full worked examples illustrating each Iron Law in a realistic scenario. Each example shows the failing code, what's wrong, and the corrected version.

## Example 1 — Developer tests mock behavior instead of real behavior

### The broken test

```rust
#[test]
fn test_user_service_initialized() {
    let mock_db = MockDatabase::new();
    let service = UserService::new(mock_db);

    // Testing that mock exists
    assert_eq!(service.database().connection_string(), "mock://test");
    assert!(service.database().is_test_mode());
}
```

### Why it fails

- Assertions check mock properties, not service behavior
- Test passes when mock is correct, fails when mock is wrong
- Tells you nothing about whether UserService works
- Would pass even if `UserService::new()` does nothing
- False confidence — mock works, but does the service?

### Applying Gate Function 1

"Am I testing real behavior or mock existence?"
→ Testing mock existence (`connection_string()`, `is_test_mode()` are mock properties).

### The fix

```rust
#[test]
fn test_user_service_creates_user() {
    let db = TestDatabase::new();  // Real test implementation
    let service = UserService::new(db);

    // Test real behavior
    let user = service.create_user("alice", "alice@example.com").unwrap();
    assert_eq!(user.name, "alice");
    assert_eq!(user.email, "alice@example.com");

    // Verify user was saved
    let retrieved = service.get_user(user.id).unwrap();
    assert_eq!(retrieved.name, "alice");
}
```

### What you gain

- Tests actual UserService behavior
- Validates create and retrieve both work
- Would fail if service broken (even with a working mock)
- Confidence the service actually works

---

## Example 2 — Developer adds test-only method to production class

### The broken code

```rust
// Production code
pub struct Database {
    pool: ConnectionPool,
}

impl Database {
    pub fn new() -> Self { /* ... */ }

    // Added "for testing"
    pub fn reset(&mut self) {
        self.pool.clear();
        self.pool.reinitialize();
    }
}

// Tests
#[test]
fn test_user_creation() {
    let mut db = Database::new();
    // ... test logic ...
    db.reset();  // Clean up
}

#[test]
fn test_user_deletion() {
    let mut db = Database::new();
    // ... test logic ...
    db.reset();  // Clean up
}
```

### Why it fails

- Production `Database` polluted with test-only `reset()`
- `reset()` looks like legitimate API to other developers
- Dangerous if accidentally called in production (clears all data!)
- Violates single responsibility (Database manages connections, not test lifecycle)
- Every test class now needs `reset()` added

### Applying Gate Function 2

"Is this only used by tests?" → YES.
"Does Database class own test lifecycle?" → NO.

### The fix

```rust
// Production code (NO reset method)
pub struct Database {
    pool: ConnectionPool,
}

impl Database {
    pub fn new() -> Self { /* ... */ }
    // No reset() — production code clean
}

// Test utilities (tests/test_utils.rs)
pub fn create_test_database() -> Database {
    Database::new()
}

pub fn cleanup_database(db: &mut Database) {
    // Access internals properly for cleanup
    if let Some(pool) = db.get_pool_mut() {
        pool.clear_test_data();
    }
}

// Tests
#[test]
fn test_user_creation() {
    let mut db = create_test_database();
    // ... test logic ...
    cleanup_database(&mut db);
}
```

### What you gain

- Production code has no test pollution
- No risk of accidental production calls
- Clear separation: Database manages connections, test utils manage test lifecycle
- Test utilities can evolve without changing production code

---

## Example 3 — Developer mocks without understanding dependencies

### The broken test

```rust
#[test]
fn test_detects_duplicate_server() {
    // "I'll mock ConfigManager to speed up the test"
    let mut mock_config = MockConfigManager::new();
    mock_config.expect_add_server()
        .times(2)
        .returning(|_| Ok(()));  // Always returns Ok!

    // Test expects duplicate detection
    mock_config.add_server(&server_config).unwrap();
    let result = mock_config.add_server(&server_config);

    // Assertion fails! Mock always returns Ok, no duplicate detection
    assert!(result.is_err());  // FAILS
}
```

### Why it fails

- Mocked `add_server()` without understanding it writes config
- Mock returns `Ok()` both times (no duplicate detection)
- Test depends on ConfigManager's internal state tracking
- Mock eliminates the behavior test needs to verify
- "Speeding up" by mocking broke the test

### Applying Gate Function 3

"What side effects does `add_server()` have?" → Writes to config file, tracks added servers.
"Does test depend on those?" → YES — test needs duplicate detection.
"Do I understand what test needs?" → Now yes.

### The fix

```rust
#[test]
fn test_detects_duplicate_server() {
    // Mock at the RIGHT level — just the slow I/O
    let mock_file_system = MockFileSystem::new();  // Mock slow file writes
    let config_manager = ConfigManager::new_with_fs(mock_file_system);

    // ConfigManager's duplicate detection still works
    config_manager.add_server(&server_config).unwrap();
    let result = config_manager.add_server(&server_config);

    // Passes! ConfigManager tracks duplicates, only file I/O is mocked
    assert!(result.is_err());
}
```

### What you gain

- Test verifies real duplicate detection logic
- Only mocked the actual slow part (file I/O)
- ConfigManager's internal tracking works normally
- Test actually validates the feature
