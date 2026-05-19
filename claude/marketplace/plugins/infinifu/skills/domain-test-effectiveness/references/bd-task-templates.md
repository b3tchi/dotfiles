# bd Task Templates for Test Quality Improvements

**Load this reference when:** Phase 7 — creating the bd epic and tasks that track the findings of a test-effectiveness audit. Use these templates; customize the placeholders for your project.

## Epic

```bash
bd create "Test Quality Improvement: [Module/Project]" \
  --type epic \
  --priority 1 \
  --design "$(cat <<'EOF'
## Goal
Improve test effectiveness by removing tautological tests, strengthening weak tests, and adding missing corner-case coverage.

## Success Criteria
- [ ] All RED tests removed or replaced with meaningful tests
- [ ] All YELLOW tests strengthened with proper assertions
- [ ] All P0 missing corner cases covered
- [ ] Mutation score ≥80% for P0 modules

## Scope
[Summary of modules analyzed and findings]

## Anti-patterns
- ❌ Adding tests that only check `!= nil`
- ❌ Adding tests that verify mock behavior
- ❌ Adding happy-path-only tests
- ❌ Leaving tautological tests "for coverage"
EOF
)"
```

## Task 1 — Remove tautological tests (P0)

```bash
bd create "Remove tautological tests from [module]" \
  --type task \
  --priority 0 \
  --design "$(cat <<'EOF'
## Goal
Remove tests that provide false confidence by passing regardless of whether production code is correct.

## Tests to Remove
[List each RED test with file:line]
- tests/auth.test.ts:45 — testUserExists (tautological: verifies non-optional != nil)
- tests/auth.test.ts:67 — testEnumHasCases (tautological: compiler checks this)

## Success Criteria
- [ ] All listed tests deleted
- [ ] No new tautological tests introduced
- [ ] Test suite still passes
- [ ] Coverage may decrease (this is expected and good)

## Anti-patterns
- ❌ Keeping tests "just in case"
- ❌ Replacing with equally meaningless tests
- ❌ Adding coverage-only tests to compensate
EOF
)"
```

## Task 2 — Strengthen weak tests (P1)

```bash
bd create "Strengthen weak assertions in [module]" \
  --type task \
  --priority 1 \
  --design "$(cat <<'EOF'
## Goal
Replace weak assertions with meaningful ones that catch real bugs.

## Tests to Strengthen
[List each YELLOW test with current vs. recommended assertion]
- tests/parser.test.ts:34 — testParse
  - Current: `expect(result).not.toBeNull()`
  - Strengthen: `expect(result).toEqual(expectedAST)`

- tests/validator.test.ts:56 — testValidate
  - Current: `expect(isValid).toBe(true)` (happy path only)
  - Add edge cases: empty input, unicode, max length

## Success Criteria
- [ ] All weak assertions replaced with exact value checks
- [ ] Edge cases added to happy-path-only tests
- [ ] Each test documents what bug it catches

## Anti-patterns
- ❌ Replacing `!= nil` with `!= undefined` (still weak)
- ❌ Adding edge cases without meaningful assertions
EOF
)"
```

## Task 3 — Add missing corner cases (P1, per module)

```bash
bd create "Add missing corner-case tests for [module]" \
  --type task \
  --priority 1 \
  --design "$(cat <<'EOF'
## Goal
Add tests for corner cases that could cause production bugs.

## Corner Cases to Add
[List each with the bug it prevents]
- test_empty_password_rejected — prevents auth bypass
- test_unicode_username_preserved — prevents encoding corruption
- test_concurrent_login_safe — prevents session corruption

## Implementation Checklist
- [ ] Write failing test first (RED)
- [ ] Verify test fails for the right reason
- [ ] Test catches the specific bug listed
- [ ] Test has meaningful assertion (not just `!= nil`)

## Success Criteria
- [ ] All corner-case tests written and passing
- [ ] Each test documents the bug it catches in test name/comment
- [ ] No tautological tests added

## Anti-patterns
- ❌ Writing a test that passes immediately (didn't test anything)
- ❌ Testing mock behavior instead of production code
- ❌ Happy path only (defeats the purpose)
EOF
)"
```

## Task 4 — Validate with mutation testing (P1)

```bash
bd create "Validate test improvements with mutation testing" \
  --type task \
  --priority 1 \
  --design "$(cat <<'EOF'
## Goal
Verify test improvements actually catch more bugs using mutation testing.

## Validation Commands
- Java: `mvn org.pitest:pitest-maven:mutationCoverage`
- JavaScript/TypeScript: `npx stryker run`
- Python: `mutmut run`
- .NET: `dotnet stryker`

## Success Criteria
- [ ] P0 modules: ≥80% mutation score
- [ ] P1 modules: ≥70% mutation score
- [ ] No surviving mutants in critical paths (auth, payments)

## If Score Below Target
- Identify surviving mutants
- Create additional tasks to add tests that kill them
- Re-run validation
EOF
)"
```

## Linking tasks

Prefer attaching each task to its epic at creation time via `--parent <epic-id>` (wires parent-child atomically). Then add blocking deps for execution order.

```bash
# At creation (recommended): add --parent <epic-id> to each of the bd create calls above.
# Example:
# bd create "Remove tautological tests" --type task --parent <epic-id> --design "..."

# Sequential: remove → strengthen → add → validate
bd dep add <strengthen-id> <remove-id>
bd dep add <add-id>        <strengthen-id>
bd dep add <validate-id>   <add-id>

# Legacy two-step parent linking (still works):
# bd dep add <task-id> <epic-id> --type parent-child
```

## Mandatory refinement pass

After creating tasks, run `infinifu:spec-refinement` on every one of them. The audit produces tasks like "add tests" or "strengthen assertions" which are exactly the kind of vague phrasing that spec-refinement catches. Do not skip this — tests written from vague tasks become the next generation of RED tests.
