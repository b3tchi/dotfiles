---
name: domain-bug-fixing
description: Use when encountering a bug - complete workflow from discovery through debugging, bd issue, test-driven fix, verification, and closure
---

<skill_overview>
Bug fixing is a complete workflow: reproduce, track in bd, debug systematically, write test, fix, verify, close. Every bug gets a bd issue and regression test.
</skill_overview>

<rigidity_level>
LOW FREEDOM — the workflow is rigid because its two most valuable steps are the ones under pressure to skip. Without a bd issue, the bug gets forgotten between context switches; without a regression test, the same bug returns in the next refactor. The debug technique and the fix itself adapt to the situation — use `infinifu:domain-debug` for investigation and `infinifu:domain-tdd` for the fix.
</rigidity_level>

<quick_reference>

| Step | Action | Command/Skill |
|------|--------|---------------|
| **1. Track** | Create bd bug issue | `bd create "Bug: [description]" --type bug` |
| **2. Debug** | Systematic investigation | Use `domain-debug` skill |
| **3. Test (RED)** | Write failing test reproducing bug | Use `domain-tdd` skill |
| **4. Fix (GREEN)** | Implement fix | Minimal code to pass test |
| **5. Verify** | Run full test suite | Use `domain-verification` skill |
| **6. Classify** | Classify status and close | `bd close bd-123` |

**Non-negotiable:** every bug gets a bd issue *before* debugging starts, and a regression test *before* the fix is committed. Both steps feel slower in the moment and pay back repeatedly — see the "why the workflow is rigid" note above.

</quick_reference>

<fix_status_values>
## Fix Status Classification

After implementing a fix, classify its status:

| Status | Definition | Next Action |
|--------|------------|-------------|
| **FIXED** | Root cause addressed, regression test passes, full suite passes | Close bd issue |
| **PARTIALLY_FIXED** | Some aspects addressed, others remain | Document what's left, keep issue open |
| **NOT_ADDRESSED** | Fix doesn't address the actual bug | Return to debugging phase |
| **CANNOT_DETERMINE** | Insufficient info to verify fix | Gather more reproduction data |

**Evidence required for each status:**
- FIXED: Regression test output showing pass, full test suite output, root cause explanation
- PARTIALLY_FIXED: List of addressed aspects with evidence, list of remaining aspects
- NOT_ADDRESSED: Explanation of why fix missed the bug, comparison to root cause
- CANNOT_DETERMINE: What information is missing, how to obtain it
</fix_status_values>

<when_to_use>
**Use when you discover a bug:**
- Test failure you need to fix
- Bug reported by user
- Unexpected behavior in development
- Regression from recent change
- Production issue (non-emergency)

**Production emergencies:** Abbreviated workflow OK (hotfix first), but still create bd issue and add regression tests afterward.
</when_to_use>

<the_process>

## 1. Create bd Bug Issue

**Track from the start:**

```bash
bd create "Bug: [Clear description]" --type bug --priority P1
# Returns: bd-123
```

**Document:**
```bash
bd edit bd-123 --design "
## Bug Description
[What's wrong]

## Reproduction Steps
1. Step one
2. Step two

## Expected Behavior
[What should happen]

## Actual Behavior
[What actually happens]

## Environment
[Version, OS, etc.]"
```

## 2. Debug Systematically

**REQUIRED: Use domain-debug skill**

```
Use Skill tool: infinifu:domain-debug
```

**domain-debug will:**
- Use internet-researcher to search for error
- Recommend debugger or instrumentation
- Use codebase-investigator to understand context
- Guide to root cause (not symptom)

**Update bd issue with findings:**
```bash
bd edit bd-123 --design "[previous content]

## Investigation
[Root cause found via debugging]
[Tools used: debugger, internet search, etc.]"
```

## 3. Write Failing Test (RED) — via `infinifu:domain-tdd`

Write a regression test that reproduces the bug, and verify it *fails before* any fix goes in. The full RED-GREEN-REFACTOR discipline and examples live in `infinifu:domain-tdd`. One bug-fix-specific note: name the test after the bd ID (e.g. `test_rejects_empty_email  # bd-123`) so future debugging trails lead back to the issue.

## 4. Implement Fix (GREEN) — via `infinifu:domain-tdd`

Implement the minimal change that makes the regression test pass, fixing at the root cause (traced via `infinifu:domain-debug` in step 2) rather than the symptom. Don't bundle unrelated changes — one fix per bd issue.

## 5. Verify Complete Fix

**REQUIRED: Use domain-verification skill**

```bash
# Run full test suite (via test-runner agent)
"Run: pytest"

# Agent returns: All tests pass (including regression test)
```

**Verify:**
- Regression test passes
- All other tests still pass
- No new warnings or errors
- Pre-commit hooks pass

## 6. Classify and Close

**REQUIRED: Classify fix status before closing:**

```bash
bd edit bd-123 --design "[previous content]

## Fix Status: FIXED
**Evidence:**
- Root cause: [explanation of what caused the bug]
- Regression test: tests/test_user.py::test_rejects_empty_email PASSES
- Full suite: 145/145 tests pass
- Fix verified: [specific verification that bug is resolved]

## Fix Implemented
[Description of fix]
[File changed: src/auth/user.py:23]

## Regression Test
[Test added: tests/test_user.py::test_rejects_empty_email]"

bd close bd-123
```

**If status is not FIXED:**
- **PARTIALLY_FIXED** → Document remaining work, create follow-up bd issue, keep original open
- **NOT_ADDRESSED** → Return to Step 2 (debugging), do not close
- **CANNOT_DETERMINE** → Gather more reproduction info before closing

**Commit with bd reference:**
```bash
git commit -m "fix(bd-123): Reject empty email in user creation

Adds validation to prevent empty strings.
Regression test: test_rejects_empty_email

Closes bd-123"
```

</the_process>

<examples>

<example>
<scenario>Developer fixes bug without creating bd issue or regression test</scenario>

<code>
Developer notices: Empty email accepted in user creation

"Fixes" immediately:
```python
def create_user(email: str):
    if not email:  # Quick fix
        raise ValidationError("Email required")
```

Commits: "fix: validate email"

[No bd issue, no regression test]
</code>

<why_it_fails>
**No tracking:**
- Work not tracked in bd (can't see what was fixed)
- No link between commit and bug
- Can't verify fix meets requirements

**No regression test:**
- Bug could come back in future
- Can't prove fix works
- No protection against breaking this again

**Incomplete fix:**
- Doesn't handle `email=" "` (whitespace)
- Didn't debug to understand full issue

**Result:** Bug returns when someone changes validation logic.
</why_it_fails>

<correction>
**Complete workflow:**

```bash
# 1. Track
bd create "Bug: Empty email accepted" --type bug
# Returns: bd-123

# 2. Debug (use domain-debug)
# Investigation reveals: Email validation missing entirely
# Also: Whitespace emails like " " also accepted

# 3. Write failing test (RED)
def test_rejects_empty_email():
    with pytest.raises(ValidationError):
        create_user(email="")

def test_rejects_whitespace_email():
    with pytest.raises(ValidationError):
        create_user(email="   ")

# Run: Both PASS (bug exists) - WAIT, test should FAIL before fix!
```

Actually:
```python
# Test currently PASSES (bug exists - no validation)
# We expect test to FAIL after we add validation

# 4. Fix
def create_user(email: str):
    if not email or not email.strip():
        raise ValidationError("Email required")

# 5. Verify
pytest  # All tests pass now, including regression tests

# 6. Close
bd close bd-123
git commit -m "fix(bd-123): Reject empty/whitespace email"
```

**Result:** Bug fixed, tracked, tested, won't regress.
</correction>
</example>

<example>
<scenario>Developer writes test after fix, test passes immediately, doesn't catch regression</scenario>

<code>
Developer fixes validation bug, then writes test:

```python
# Fix first
def validate_email(email):
    return "@" in email and len(email) > 0

# Then test
def test_validate_email():
    assert validate_email("user@example.com") == True
```

Test runs: PASS

Commits both together.

Later, someone changes validation:
```python
def validate_email(email):
    return True  # Breaks validation!
```

Test still PASSES (only checks happy path).
</code>

<why_it_fails>
**Test written after fix:**
- Never saw test fail
- Only tests happy path remembered
- Doesn't test the bug that was fixed
- Missed edge case: `validate_email("@@")` returns True (bug!)

**Why it happens:** Skipping TDD RED phase.
</why_it_fails>

<correction>
**TDD approach (RED-GREEN):**

```python
# 1. Write test FIRST that reproduces the bug
def test_validate_email():
    # Happy path
    assert validate_email("user@example.com") == True
    # Bug case (empty email was accepted)
    assert validate_email("") == False
    # Edge case discovered during debugging
    assert validate_email("@@") == False

# 2. Run test - should FAIL (bug exists)
pytest test_validate_email
# FAIL: validate_email("") returned True, expected False

# 3. Implement fix
def validate_email(email):
    if not email or len(email) == 0:
        return False
    return "@" in email and email.count("@") == 1

# 4. Run test - should PASS
pytest test_validate_email
# PASS: All assertions pass
```

**Later regression:**
```python
def validate_email(email):
    return True  # Someone breaks it
```

**Test catches it:**
```
FAIL: assert validate_email("") == False
Expected False, got True
```

**Result:** Regression test actually prevents bug from returning.
</correction>
</example>

<example>
<scenario>Developer fixes symptom without using domain-debug to find root cause</scenario>

<code>
Bug report: "Application crashes when processing user data"

Error:
```
NullPointerException at UserService.java:45
```

Developer sees line 45:
```java
String email = user.getEmail().toLowerCase();  // Line 45
```

"Obvious fix":
```java
String email = user.getEmail() != null ? user.getEmail().toLowerCase() : "";
```

Bug "fixed"... but crashes continue with different data.
</code>

<why_it_fails>
**Symptom fix:**
- Fixed null check at crash point
- Didn't investigate WHY email is null
- Didn't use domain-debug to find root cause

**Actual root cause:** User object created without email in registration flow. Email is null for all users created via broken endpoint.

**Result:** Null-check applied everywhere, root cause (broken registration) unfixed.
</why_it_fails>

<correction>
**Use domain-debug skill:**

```
# Dispatch internet-researcher
"Search for: NullPointerException UserService getEmail
- Common causes of null email in user objects
- User registration validation patterns"

# Dispatch codebase-investigator
"Investigate:
- How is User object created?
- Where is email set?
- Are there paths where email can be null?
- Which endpoints create users?"

# Agent reports:
"Found: POST /register endpoint creates User without validating email field.
Email is optional in UserDTO but required in User domain object."
```

**Root cause found:** Registration doesn't validate email.

**Proper fix:**
```java
// In registration endpoint
@PostMapping("/register")
public User register(@RequestBody UserDTO dto) {
    if (dto.getEmail() == null || dto.getEmail().isEmpty()) {
        throw new ValidationException("Email required");
    }
    return userService.create(dto);
}
```

**Regression test:**
```java
@Test
void registrationRequiresEmail() {
    assertThrows(ValidationException.class, () ->
        register(new UserDTO(null, "password")));
}
```

**Result:** Root cause fixed, no more null emails created.
</correction>
</example>

</examples>

<critical_rules>

## Rules That Have No Exceptions

1. **Every bug gets a bd issue** → Track from discovery to closure
   - Create bd issue before fixing
   - Document reproduction steps
   - Update with investigation findings
   - Close only after verified

2. **Use domain-debug skill** → Systematic investigation required
   - Never guess at fixes
   - Use internet-researcher for errors
   - Use debugger/instrumentation for state
   - Find root cause, not symptom

3. **Write failing test first (RED)** → Regression prevention
   - Test must fail before fix
   - Test must reproduce the bug
   - Test must pass after fix
   - If test passes immediately, it doesn't test the bug

4. **Verify complete fix** → Use domain-verification
   - Regression test passes
   - Full test suite passes
   - No new warnings
   - Pre-commit hooks pass

## Common Excuses

All of these mean: Stop, follow complete workflow:
- "Quick fix, no need for bd issue"
- "Obvious bug, no need to debug"
- "I'll add test later"
- "Test passes, must be fixed"
- "Just one line change"

</critical_rules>

<verification_checklist>

Before claiming bug fixed:
- [ ] bd issue created with reproduction steps
- [ ] Used domain-debug to find root cause
- [ ] Wrote test that reproduces bug (RED phase)
- [ ] Verified test FAILS before fix
- [ ] Implemented fix addressing root cause
- [ ] Verified test PASSES after fix
- [ ] Ran full test suite (all pass)
- [ ] Updated bd issue with fix details
- [ ] Closed bd issue
- [ ] Committed with bd reference

</verification_checklist>

<integration>

**This skill calls:**
- domain-debug (systematic investigation)
- domain-tdd (RED-GREEN-REFACTOR cycle)
- domain-verification (verify complete fix)

**This skill is called by:**
- When bugs discovered during development
- When test failures need fixing
- When user reports bugs

**Agents used:**
- infinifu:internet-researcher (via domain-debug)
- infinifu:codebase-investigator (via domain-debug)
- infinifu:test-runner (run tests without output pollution)

</integration>

<resources>

**When stuck:**
- Don't understand bug → Use domain-debug skill
- Tempted to skip tracking → Create bd issue first, always
- Test passes immediately → Not testing the bug, rewrite test
- Fix doesn't work → Return to domain-debug, find actual root cause

</resources>
