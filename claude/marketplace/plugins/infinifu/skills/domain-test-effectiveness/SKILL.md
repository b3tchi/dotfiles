---
name: domain-test-effectiveness
description: Use to audit an existing test suite with senior-SRE scrutiny — identifies tautological tests, coverage gaming, weak assertions, and missing corner cases, then creates a bd epic with tracked improvement tasks. Invoke this whenever production bugs keep appearing despite high coverage, before major refactoring, or when onboarding to an unfamiliar codebase.
---

<skill_overview>
Audit a test suite for real effectiveness, not vanity metrics. Identify tests that provide false confidence (tautological, mock-testing, line hitters), find missing corner cases, prioritize by business impact, and track every finding in bd with tasks that are themselves refined before execution.

The working assumption: tests were written by a team optimizing for coverage metrics. Default to skeptical — a test is RED or YELLOW until proven GREEN, and GREEN is the exception. You must read production code before categorizing any test.
</skill_overview>

<rigidity_level>
MEDIUM FREEDOM — the phase order is fixed and the RED/YELLOW/GREEN criteria are rigid because their value depends on applying them uniformly. What adapts: which corner cases matter for the specific codebase, and the output format for the final report.
</rigidity_level>

<quick_reference>
| Phase | Action | Output |
|-------|--------|--------|
| 1. Inventory | List all test files and functions | Test catalog |
| 2. Read production code | Read what each test claims to exercise | Context for analysis |
| 3. Categorize (skeptical) | Apply RED/YELLOW/GREEN — default to harsher rating | Categorized tests |
| 4. Self-review | Challenge every GREEN | Validated categories |
| 5. Corner cases | Identify missing edge cases per module | Gap analysis |
| 6. Prioritize | Rank by business criticality | Priority matrix |
| 7. bd issues | Create epic + tasks, run spec-refinement | Tracked improvement plan |

**Read production code before categorizing.** You cannot assess a test without understanding what it claims to test. This is the single most common cause of false-GREEN classifications.

**Core questions for each test:**
1. What bug would this catch? *(Can't name one → RED)*
2. Does it exercise production code or a mock/test utility? *(Mock → RED or YELLOW)*
3. Could code break while the test still passes? *(Yes → YELLOW or RED)*
4. Is the assertion meaningful? *(`!= nil` or checking fixtures → weak)*

**Mutation testing validates the audit:**
- Java: Pitest (`mvn org.pitest:pitest-maven:mutationCoverage`)
- JS/TS: Stryker (`npx stryker run`)
- Python: mutmut (`mutmut run`)
- .NET: Stryker.NET (`dotnet stryker`)
</quick_reference>

<when_to_use>
**Use when:**
- Production bugs appear despite high test coverage
- You suspect coverage gaming or tautological tests
- Before major refactoring (ensure tests will catch regressions)
- Onboarding to an unfamiliar codebase (assess test quality)
- After `infinifu:work-audit` flags test quality issues
- Planning a test improvement initiative

**Don't use when:**
- Writing new tests — use `infinifu:domain-tdd`
- Debugging a test failure — use `infinifu:domain-debug`
- Just running tests — use the `test-runner` agent
</when_to_use>

<the_process>

## Announcement

"I'm using infinifu:domain-test-effectiveness to audit test quality with senior-SRE scrutiny."

## Phase 1 — Inventory

Build a complete catalog of tests. Adapt patterns to the language:

```bash
# Find test files
fd -e test.ts -e spec.ts -e _test.go -e Test.java -e test.py .

# Find test functions
rg "func Test|it\(|test\(|def test_|@Test" --type-add 'test:*test*' -t test

# Count tests per module
for dir in src/*/; do
  count=$(rg -c "func Test|it\(" "$dir" 2>/dev/null | wc -l)
  echo "$dir: $count tests"
done
```

Track modules with a TodoWrite list so you don't drop any.

## Phase 2 — Read production code first

Before categorizing any test:

1. Read the production code the test claims to exercise
2. Understand what it actually does
3. Trace the test's call path to verify it reaches production code

Why this matters: the most common cause of false GREENs is categorizing a test as good without checking whether it actually exercises production code. Engineers write tests that set up elaborate mocks, then assert on values defined in the test itself. Those tests pass reliably and catch nothing. You will not notice this without reading the production code.

## Phase 3 — Categorize (skeptical default)

Assume every test is RED or YELLOW until concrete evidence proves GREEN. Full taxonomy with code examples and detection patterns lives in `references/categorization-catalog.md` — load it now. Summary:

- **RED (remove/replace):** tautological, mock-testing, line hitters, evergreen/liar tests
- **YELLOW (strengthen):** happy-path-only, weak assertions, partial coverage
- **GREEN (keep):** exercises production code, precise assertions, would fail on real breakage, tests behavior not implementation

**For every RED or YELLOW classification, write a line-by-line justification.** The format is mandatory because it forces you to verify your own reasoning. See `references/justification-format.md` for the structure and two worked examples.

## Phase 4 — Self-review

Before finalizing, re-examine every GREEN classification with the self-challenge questions in `references/categorization-catalog.md`. The purpose is not paranoia — it's catching the GREENs you gave the benefit of the doubt to when you were tired. A false GREEN is worse than a false YELLOW because it removes the signal that something needs attention.

If more than 40% of tests end up GREEN, re-review with more skepticism. Good test suites from careful teams still typically have more YELLOW than GREEN — most tests have room to strengthen.

## Phase 5 — Corner-case discovery

For each module, identify missing corner-case tests. Use these categories as prompts:

**Input validation:**

| Category | Examples | Tests to add |
|----------|----------|--------------|
| Empty values | `""`, `[]`, `{}`, `null` | `test_empty_X_rejected` |
| Boundary values | 0, -1, MAX_INT, MAX_LEN | `test_boundary_X_handled` |
| Unicode | RTL, emoji, combining chars, null byte | `test_unicode_X_preserved` |
| Injection | SQL, XSS, command injection | `test_injection_X_escaped` |
| Malformed | truncated JSON, invalid UTF-8, wrong type | `test_malformed_X_error` |

**State:**

| Category | Examples | Tests to add |
|----------|----------|--------------|
| Uninitialized | use before init, double init | `test_uninitialized_X_error` |
| Already closed | use after close, double close | `test_closed_X_error` |
| Concurrent | parallel writes, read during write | `test_concurrent_X_safe` |
| Re-entrant | callback calls same method | `test_reentrant_X_safe` |

**Integration:**

| Category | Examples | Tests to add |
|----------|----------|--------------|
| Network | timeout, connection refused, DNS fail | `test_network_X_timeout` |
| Partial response | truncated, corrupted, slow | `test_partial_response_handled` |
| Rate limiting | 429, quota exceeded | `test_rate_limit_handled` |
| Service errors | 500, 503, malformed response | `test_service_error_handled` |

**Resources:**

| Category | Examples | Tests to add |
|----------|----------|--------------|
| Exhaustion | OOM, disk full, max connections | `test_resource_X_graceful` |
| Contention | file locked, resource busy | `test_contention_X_handled` |
| Permissions | access denied, read-only | `test_permission_X_error` |

For each module, produce a checklist of covered vs. missing corner cases, with priority based on how business-critical the module is.

## Phase 6 — Prioritize by business impact

| Priority | Criteria | Action timeline |
|----------|----------|-----------------|
| P0 — Critical | Auth, payments, data integrity | This sprint |
| P1 — High | Core business logic, user-facing features | Next sprint |
| P2 — Medium | Internal tools, admin features | Backlog |
| P3 — Low | Utilities, non-critical paths | As time permits |

Rank modules so the bd tasks reflect what to fix first.

## Phase 7 — Create bd issues and run refinement

Every finding is tracked in bd. The templates in `references/bd-task-templates.md` cover:

- The top-level epic
- Task 1: remove tautological tests (P0)
- Task 2: strengthen weak assertions (P1)
- Task 3: add missing corner cases (P1, per module)
- Task 4: validate with mutation testing (P1)
- Linking and dependency commands

**After creating tasks, run `infinifu:spec-refinement` on every one.** Audit output tends to produce tasks like "add tests" or "strengthen assertions" — exactly the vague phrasing spec-refinement catches. Tests written from vague tasks become the next generation of RED tests; refinement prevents the regression.

## Output format

```markdown
# Test Effectiveness Analysis: [Project Name]

## Executive Summary

| Metric | Count | % |
|--------|-------|---|
| Total tests analyzed | N | 100% |
| RED (remove/replace) | N | X% |
| YELLOW (strengthen) | N | X% |
| GREEN (keep) | N | X% |
| Missing corner cases | N | — |

**Overall Assessment:** [CRITICAL / NEEDS WORK / ACCEPTABLE / GOOD]

## Detailed Findings

### RED Tests (must remove/replace)
[Tables per sub-category: tautological, mock-testing, line hitters, evergreen]

### YELLOW Tests (must strengthen)
[Tables per sub-category: weak assertions, happy-path-only]

### GREEN Tests (exemplars)
[3-5 tests that exemplify good testing practices for this codebase]

## Missing Corner Cases by Module
[Per-module table: corner case | bug risk | recommended test]

## bd Issues Created
[Epic + tasks + dependency tree]

## SRE Refinement Status
[Confirmation that spec-refinement has been applied to every task]

## Next Steps
1. Run `bd ready`
2. Implement tasks via `infinifu:plan-scrum-master` or `infinifu:plan-supervised`
3. Run the validation task to verify improvements
```

</the_process>

<critical_rules>
1. **Assume low quality by default.** Tests are RED or YELLOW until proven GREEN.
2. **Read production code before categorizing.** You cannot assess without context.
3. **GREEN is the exception.** Most tests are RED or YELLOW — GREEN requires specific proof.
4. **Every test must answer: "What bug does this catch?"** If no answer, it's RED.
5. **Self-review before finalizing.** Challenge every GREEN.
6. **Track everything in bd.** Untracked work becomes forgotten work.
7. **Run spec-refinement on audit tasks.** Vague audit tasks produce the next round of bad tests.
8. **Mutation testing validates.** Coverage alone is a vanity metric.

## Common excuses

All of these mean the test is probably RED or YELLOW:

- *"It's just a smoke test"* — smoke tests without assertions are useless
- *"Coverage requires it"* — coverage gaming creates false confidence
- *"It worked before"* — past success doesn't mean it catches bugs
- *"Mocks make it faster"* — fast but useless is still useless
- *"Edge cases are rare"* — rare bugs in auth/payments are critical
- *"The test looks reasonable"* — plausible-looking garbage still passes by definition
- *"The test name says it tests X"* — names lie; trace the actual code
- *"It exercises the function"* — calling ≠ testing; assertions are what matters
- *"I'll just fix these without bd"* — untracked work becomes forgotten work

A false GREEN is worse than a false YELLOW. When in doubt, be harsher.
</critical_rules>

<verification_checklist>
**Analysis quality:**
- [ ] Read production code for every test before categorizing
- [ ] Traced call paths to verify tests exercise production, not mocks/utilities
- [ ] Applied skeptical default (assumed RED/YELLOW, required proof for GREEN)
- [ ] Completed self-review for all GREEN tests
- [ ] Each GREEN has explicit justification (production path + specific bug it catches)
- [ ] Each RED/YELLOW has line-by-line justification

**Per module:**
- [ ] All tests categorized
- [ ] Corner cases identified (empty, unicode, concurrent, error)
- [ ] Priority assigned (P0/P1/P2/P3)

**Overall:**
- [ ] GREEN count is a minority (if >40% GREEN, re-review with more skepticism)
- [ ] Executive summary with counts and percentages
- [ ] Detailed findings per category
- [ ] Missing corner cases documented per module

**bd integration:**
- [ ] Created epic for test quality improvement
- [ ] Created tasks for each category (remove, strengthen, add)
- [ ] Linked tasks to epic with parent-child
- [ ] Set dependencies (remove → strengthen → add → validate)
- [ ] Ran `infinifu:spec-refinement` on every task
- [ ] Created validation task with mutation testing
</verification_checklist>

<integration>
**Called by:**
- `infinifu:work-audit` when test quality issues are flagged
- User request to audit test quality
- Before major refactoring efforts

**Calls:**
- `infinifu:spec-refinement` — mandatory, on every task created
- `test-runner` agent — run tests during analysis
- `test-effectiveness-analyst` agent — detailed analysis pass

**Informs:**
- `infinifu:spec-refinement` — Category 8 (test meaningfulness) uses the same RED/YELLOW/GREEN mental model
- `infinifu:domain-tdd` — what makes a good test

**Workflow chain:**

```
domain-test-effectiveness
    ↓ creates bd issues
spec-refinement (on each task)
    ↓ refines tasks
plan-scrum-master / plan-supervised (implements tasks)
    ↓ runs validation
work-audit (verifies quality)
```
</integration>

<references>
- `references/categorization-catalog.md` — full RED/YELLOW/GREEN taxonomy with detection patterns and code examples for each sub-category
- `references/justification-format.md` — the mandatory line-by-line justification format with worked examples
- `references/bd-task-templates.md` — epic and task creation templates plus linking commands
- `references/examples.md` — two end-to-end audit walkthroughs (high-coverage-with-bugs, mock-heavy suite)
</references>

<further_reading>
- [Google Testing Blog: Code Coverage Best Practices](https://testing.googleblog.com/2020/08/code-coverage-best-practices.html) — *"Coverage mainly tells you about code that has no tests: it doesn't tell you about the quality of testing for the code that's 'covered'."*
- [Software Testing Anti-patterns](https://blog.codepipes.com/testing/software-testing-antipatterns.html)
- [Tautological Tests](https://randycoulman.com/blog/2016/12/20/tautological-tests/)
- [Mutation Testing Guide](https://mastersoftwaretesting.com/testing-fundamentals/types-of-testing/mutation-testing)
- [Google SRE: Testing Reliability](https://sre.google/sre-book/testing-reliability/)
</further_reading>
