---
name: domain-refactor-safely
description: Use during refactoring to execute the change→test→commit cycle in small safe steps — tests stay green between every change, each commit is independently revertible. This is the *execution* skill; for the diagnosis phase (what to refactor and why), use idea-refactoring first.
---

<skill_overview>
Refactoring changes code structure without changing behavior; tests must stay green throughout or you're rewriting, not refactoring.
</skill_overview>

<rigidity_level>
MEDIUM FREEDOM — the change→test→commit cycle is rigid because bundling changes is how refactors silently introduce bugs. Commit each safe change separately; when something breaks, you can revert exactly one step instead of hunting through a 500-line diff. The refactoring patterns themselves adapt to the language and codebase.
</rigidity_level>

<quick_reference>
| Step | Action | Verify |
|------|--------|--------|
| 1 | Run full test suite before starting | ALL pass |
| 2 | Make ONE small change | Compiles |
| 3 | Run tests immediately | ALL still pass |
| 4 | Commit with descriptive message | History clear |
| 5 | Repeat 2-4 until complete | Each step safe |
| 6 | Final verification (tests + linter clean) | Done |

**Core cycle:** Change → Test → Commit (repeat until complete). Each small commit is the revertible unit — that's the safety net, not the bd task.
</quick_reference>

<when_to_use>
- Improving code structure without changing functionality
- Extracting duplicated code into shared utilities
- Renaming for clarity
- Reorganizing file/module structure
- Simplifying complex code while preserving behavior

**Don't use for:**
- Changing functionality (use feature development)
- Fixing bugs (use infinifu:domain-bug-fixing)
- Adding features while restructuring (do separately)
- Code without tests (write tests first using infinifu:domain-tdd)
</when_to_use>

<the_process>
## 1. Verify Tests Pass Before Starting

Refactoring without a green test suite is not refactoring — you have no way to detect when your change alters behavior. Run the full suite (dispatch `infinifu:test-runner` to keep context clean). If anything fails, fix it first, then start refactoring.

---

## 2. Make ONE Small Change

The smallest transformation that compiles.

**Examples of "small":**
- Extract one method
- Rename one variable
- Move one function to different file
- Inline one constant
- Extract one interface

**NOT small:**
- Extracting multiple methods at once
- Renaming + moving + restructuring
- "While I'm here" improvements

**Example:**

```rust
// Before
fn create_user(name: &str, email: &str) -> Result<User> {
    if email.is_empty() {
        return Err(Error::InvalidEmail);
    }
    if !email.contains('@') {
        return Err(Error::InvalidEmail);
    }

    let user = User { name, email };
    Ok(user)
}

// After - ONE small change (extract email validation)
fn create_user(name: &str, email: &str) -> Result<User> {
    validate_email(email)?;

    let user = User { name, email };
    Ok(user)
}

fn validate_email(email: &str) -> Result<()> {
    if email.is_empty() {
        return Err(Error::InvalidEmail);
    }
    if !email.contains('@') {
        return Err(Error::InvalidEmail);
    }
    Ok(())
}
```

---

## 3. Run Tests Immediately

After every small change, run the full suite — delayed tests don't tell you *which* change broke things. If any test fails: **stop**, `git restore` the change, figure out why, and make a smaller change. Never proceed on red.

---

## 4. Commit the Small Change

Each passing, scoped change is its own commit. The commit is the revertible unit: when the next step breaks, you revert one commit, not a day's work. Clear commit message per transformation (e.g. `refactor: extract email validation`).

---

## 5. Repeat Until Complete

Cycle steps 2–4 until the refactor is done:

```
1. Extract validate_email()   → test → commit
2. Extract validate_name()    → test → commit
3. Create UserValidator       → test → commit
4. Move validations in        → test → commit
5. Update UserService         → test → commit
6. Remove duplicates elsewhere → test → commit
```

If you've made 3+ consecutive failing attempts, the approach is probably wrong — see "When to Rewrite" below.

---

## 6. Final Verification

Confirm the end state meets the refactor bar:

- Full test suite green (dispatch `infinifu:test-runner`)
- Linter clean — no new warnings
- No behavior changes (review `git diff main...HEAD`)
- Each commit in the history is small and independently revertible

If the refactor is being tracked in bd, closing the task is the caller's process concern (`work-do` or whatever dispatched this refactor) — this skill's job ends when the code state passes the bar above.
</the_process>

<examples>
<example>
<scenario>Developer changes behavior while "refactoring"</scenario>

<code>
// Original code
fn validate_email(email: &str) -> Result<()> {
    if email.is_empty() {
        return Err(Error::InvalidEmail);
    }
    if !email.contains('@') {
        return Err(Error::InvalidEmail);
    }
    Ok(())
}

// "Refactored" version
fn validate_email(email: &str) -> Result<()> {
    if email.is_empty() {
        return Err(Error::InvalidEmail);
    }
    if !email.contains('@') {
        return Err(Error::InvalidEmail);
    }
    // NEW: Added extra validation
    if !email.contains('.') {  // BEHAVIOR CHANGE
        return Err(Error::InvalidEmail);
    }
    Ok(())
}
</code>

<why_it_fails>
- This changes behavior (now rejects emails like "user@localhost")
- Tests might fail, or worse, pass and ship breaking change
- Not refactoring - this is modifying functionality
- Users who relied on old behavior experience regression
</why_it_fails>

<correction>
**Correct approach:**

1. Extract validation (pure refactoring, no behavior change)
2. Commit with tests passing
3. THEN add new validation as separate feature with new tests
4. Two clear commits: refactoring vs. feature addition

**What you gain:**
- Clear history of what changed when
- Easy to revert feature without losing refactoring
- Tests document exact behavior changes
- No surprises in production
</correction>
</example>

<example>
<scenario>Developer does big-bang refactoring</scenario>

<code>
# Changes made all at once:
- Renamed 15 functions across 5 files
- Extracted 3 new classes
- Moved code between 10 files
- Reorganized module structure
- Updated all import statements

# Then runs tests
$ cargo test
... 23 test failures ...

# Now what? Which change broke what?
</code>

<why_it_fails>
- Can't identify which specific change broke tests
- Reverting means losing ALL work
- Fixing requires re-debugging entire refactoring
- Wastes hours trying to untangle failures
- Might give up and revert everything
</why_it_fails>

<correction>
**Correct approach:**

1. Rename ONE function → test → commit
2. Extract ONE class → test → commit
3. Move ONE file → test → commit
4. Continue one change at a time

**If test fails:**
- Know exactly which change broke it
- Revert ONE commit, not all work
- Fix or make smaller change
- Continue from known-good state

**What you gain:**
- Tests break → immediately know why
- Each commit is reviewable independently
- Can stop halfway with useful progress
- Confidence from continuous green tests
- Clear history for future developers
</correction>
</example>

<example>
<scenario>Developer refactors code without tests</scenario>

<code>
// Legacy code with no tests
fn process_payment(amount: f64, user_id: i64) -> Result<PaymentId> {
    // 200 lines of complex payment logic
    // Multiple edge cases
    // No tests exist
}

// Developer refactors without tests:
// - Extracts 5 methods
// - Renames variables
// - Simplifies conditionals
// - "Looks good to me!"

// Deploys to production
// 💥 Payments fail for amounts over $1000
// Edge case handling was accidentally changed
</code>

<why_it_fails>
- No tests to verify behavior preserved
- Complex logic has hidden edge cases
- Subtle behavior changes go unnoticed
- Breaks in production, not development
- Costs customer trust and emergency debugging
</why_it_fails>

<correction>
**Correct approach:**

1. **Write tests FIRST** (using infinifu:domain-tdd)
   - Test happy path
   - Test all edge cases (amounts over $1000, etc.)
   - Test error conditions
   - Run tests → all pass (documenting current behavior)

2. **Then refactor with tests as safety net**
   - Extract method → run tests → commit
   - Rename → run tests → commit
   - Simplify → run tests → commit

3. **Tests catch any behavior changes immediately**

**What you gain:**
- Confidence behavior is preserved
- Edge cases documented in tests
- Catches subtle changes before production
- Future refactoring is also safe
- Tests serve as documentation
</correction>
</example>
</examples>

<refactor_vs_rewrite>
## When to Refactor

- Tests exist and pass
- Changes are incremental
- Business logic stays same
- Can transform in small, safe steps
- Each step independently valuable

## When to Rewrite

- No tests exist (write tests first, then refactor)
- Fundamental architecture change needed
- Easier to rebuild than modify
- Requirements changed significantly
- After 3+ failed refactoring attempts

**Rule:** If you need to change test assertions (not just add tests), you're rewriting, not refactoring.

## Strangler Fig Pattern (Hybrid)

**When to use:**
- Need to replace legacy system but can't tolerate downtime
- Want incremental migration with continuous monitoring
- System too large to refactor in one go

**How it works:**

1. **Transform:** Create modernized components alongside legacy
2. **Coexist:** Both systems run in parallel (façade routes requests)
3. **Eliminate:** Retire old functionality piece by piece

**Example:**

```
Legacy: Monolithic user service (50K LOC)
Goal: Microservices architecture

Step 1 (Transform):
- Create new UserService microservice
- Implement user creation endpoint
- Tests pass in isolation

Step 2 (Coexist):
- Add routing layer (façade)
- Route POST /users to new service
- Route GET /users to legacy service (for now)
- Monitor both, compare results

Step 3 (Eliminate):
- Once confident, migrate GET /users to new service
- Remove user creation from legacy
- Repeat for remaining endpoints
```

**Benefits:**
- Incremental replacement reduces risk
- Legacy continues operating during transition
- Can pause/rollback at any point
- Each migration step is independently valuable

**Use refactoring within components, Strangler Fig for replacing systems.**
</refactor_vs_rewrite>

<critical_rules>
## Rules That Have No Exceptions

1. **Tests must stay green** throughout refactoring → If they fail, you changed behavior (stop and undo)
2. **Commit after each small change** → Large commits hide which change broke what
3. **One transformation at a time** → Multiple changes = impossible to debug failures
4. **Run tests after EVERY change** → Delayed testing doesn't tell you which change broke it
5. **If tests fail 3+ times, question approach** → Might need to rewrite instead, or add tests first

## Common Excuses

All of these mean: **Stop and return to the change→test→commit cycle**

- "Small refactoring, don't need tests between steps"
- "I'll test at the end"
- "Tests are slow, I'll run once at the end"
- "Just fixing bugs while refactoring" (bug fixes = behavior changes = not refactoring)
- "Easier to do all at once"
- "I know it works without tests"
- "While I'm here, I'll also..." (scope creep during refactoring)
- "Tests will fail temporarily but I'll fix them" (tests must stay green)
</critical_rules>

<verification_checklist>
Before marking refactoring complete:

- [ ] All tests pass (verified with infinifu:test-runner agent)
- [ ] No new linter warnings
- [ ] No behavior changes introduced
- [ ] Code is cleaner/simpler than before
- [ ] Each commit in history is small and safe
- [ ] Can explain what each transformation did

**Can't check all boxes?** Return to the change → test → commit cycle and fix before declaring done.
</verification_checklist>

<integration>
**This skill requires:**
- infinifu:domain-tdd (for writing tests before refactoring if none exist)
- infinifu:domain-verification (for final verification)
- infinifu:test-runner agent (for running tests without context pollution)

**This skill is called by:**
- General development workflows when improving code structure
- After features are complete and working
- When preparing code for new features

**Agents used:**
- test-runner (runs tests/commits without polluting main context)
</integration>

<resources>
**Detailed guides:**
- [Common refactoring patterns](references/refactoring-patterns.md) - Extract Method, Extract Class, Inline, etc.
- [Complete refactoring session example](references/example-session.md) - Minute-by-minute walkthrough

**When stuck:**
- Tests fail after change → Undo (git restore), make smaller change
- 3+ failures → Question if refactoring is right approach, consider rewrite
- No tests exist → Use infinifu:domain-tdd to write tests first
- Unsure how small → If it touches more than one function/file, it's too big
</resources>
