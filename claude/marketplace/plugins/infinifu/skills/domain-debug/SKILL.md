---
name: domain-debug
description: Use when investigating a bug, test failure, or unexpected behavior before proposing a fix — gathers evidence with tools, forms a hypothesis, and tests it at the root cause, not the symptom. Invoke this whenever you catch yourself about to "just try" a change to see if it works.
---

<skill_overview>
Debugging is evidence collection, not guessing. Gather data with tools, form a hypothesis you can state in one sentence, test it with the smallest possible change, then fix at the source — not where the symptom appears.
</skill_overview>

<rigidity_level>
MEDIUM FREEDOM — the four phases (investigate → hypothesize → test → fix) are non-negotiable because skipping phase 1 is how random fixes get attempted. Tool choice and instrumentation style adapt to the language and codebase.
</rigidity_level>

<quick_reference>
| Phase | What you do | What you produce |
|-------|-------------|------------------|
| 1. Investigate | Read the full error, reproduce, search the internet for the exact message, inspect state with a debugger or instrumentation, read surrounding code | Evidence — facts, not theories |
| 2. Hypothesize | State in one sentence: "I think *X* is the root cause because *Y* (evidence)" | A falsifiable claim |
| 3. Test | Make the smallest change that proves or disproves the hypothesis | Confirmed theory, or return to phase 1 |
| 4. Fix | Write a failing regression test, then fix at the source, then verify | Root-cause fix + regression test |

**Why four phases matter:** phase 1 is the one everyone skips under time pressure. If you skip it, your first fix is a guess, your guess misses, and now you are in a loop where each guess creates new symptoms. Systematic debugging is *faster* than guess-and-check — the difference is 15 minutes vs two hours.
</quick_reference>

<when_to_use>
- A test fails and you don't already know why
- An error appears in production or development
- Behavior doesn't match expectation
- A previous fix didn't stick, or a new symptom appeared
- You're about to open a PR titled "try X" — stop, come here first

**Don't use for:**
- Full bug workflow with bd tracking and regression gate — use `infinifu:domain-bug-fixing`, which calls this skill
- Just running tests — use the `test-runner` agent

**Escalate to root-cause tracing** (see `references/root-cause-tracing.md`) when the error is deep in the call stack and you don't yet know where the bad data originated.
</when_to_use>

<the_process>

## Phase 1 — Investigate

You are not allowed to propose a fix in this phase. The goal is evidence.

### Read the error completely

Read the whole message and the whole stack trace. Note line numbers, file paths, error codes. Error messages often contain the exact answer in the second-to-last line, not the first.

### Reproduce it

Can you trigger it reliably? What are the exact steps? If not reproducible, keep gathering data — don't guess. An unreproducible bug plus a guess-fix is a recipe for shipping broken code that appears to work.

### Search the internet for the exact error

Most errors have been seen before. Dispatch the `internet-researcher` agent with the *verbatim* error text:

> Search for error: `[exact error message]`. Check Stack Overflow, look for GitHub issues in [library] version [X], find official docs, check for known bugs.

A 30-second agent run beats two hours of reinvention. This step is cheap — skip it only when the error is obviously specific to your codebase.

### Inspect state

Claude cannot run interactive debuggers, so:

- **Option A — guide your human partner:** write out the debugger commands for them, ask them to run and share output. See `references/debugger-reference.md` for LLDB/GDB/DevTools command recipes.
- **Option B — add instrumentation:** print or log the state at the error site. Use `eprintln!`/`console.error` so output survives test harnesses that suppress stdout. Capture a backtrace if the call chain is unclear.

### Investigate the codebase

Dispatch `codebase-investigator` with a focused question:

> Error is at `X:Y`. Find callers, find what variable `Z` contains at this point, find similar code that works, find what changed recently.

### When the error is deep — trace backward

If the error location is a utility or library and the real bug is higher up, use the backward-tracing technique: step back one stack frame at a time, asking "why did *this* code receive bad input?" until you find where the bad data was created. Full walkthrough in `references/root-cause-tracing.md`.

### When a test run pollutes state — find the polluter

If state leaks between tests (the classic "runs fine alone, fails in suite"), use the binary-search polluter-finder script at `references/find-polluter.sh`.

---

## Phase 2 — Hypothesize

State your theory in one sentence. The format matters:

> "I think *X* is the root cause because *Y*."

`Y` must cite evidence from phase 1. If you can only fill in `X` and not `Y`, you're guessing — return to phase 1.

Make one hypothesis at a time. Multiple parallel theories mean you don't know enough yet.

---

## Phase 3 — Test

Make the smallest possible change that confirms or refutes the hypothesis. One variable at a time.

- **Confirmed?** → Phase 4.
- **Refuted?** → Return to phase 1 with the new evidence. Do *not* stack fixes on top of a refuted hypothesis.
- **After 3 failed hypotheses in a row** → the problem may be architectural, not local. Read `references/when-fixes-keep-failing.md` before attempting a fourth.

---

## Phase 4 — Fix

### Write the failing test first

A bug without a regression test is a bug that will return. Use `infinifu:domain-tdd` to write the failing test before touching production code.

### Fix at the source, not the symptom

If phase 1 traced the bug back to its origin, fix it there. A validation check added at the error site is a band-aid — the same bad value will appear somewhere else tomorrow.

After fixing the source, optionally add defense-in-depth: assertions at layer boundaries that catch the bad value if the source check ever regresses. See `references/defense-in-depth.md`. Defense is backup, not substitute.

### Verify

- The new regression test passes.
- The full test suite still passes.
- The original symptom is gone.

Use `infinifu:domain-verification` to gate the "fixed" claim behind actual test output.

</the_process>

<red_flags>
If you catch yourself thinking any of these, stop and return to phase 1:

- "Quick fix for now, investigate later" — the quick fix becomes the permanent fix
- "Just try changing X and see if it works" — that's a guess, not a hypothesis
- "Error message is clear enough, skip the search" — 30 seconds of searching saves hours
- "I'll write the test after I confirm the fix" — untested fixes don't stick
- "One more fix attempt" after 2+ failures — you're treating symptoms
- "Stack trace shows the problem" — it shows the symptom *location*, not the source
- Proposing a solution before phase 1 is complete

Also watch for redirection signals from your human partner:
- "Is that not happening?" — you assumed without verifying
- "Stop guessing" — you jumped to phase 4
- "We're stuck?" (frustrated) — your approach isn't working; return to phase 1
</red_flags>

<verification_checklist>
Before proposing any fix:
- [ ] Read the complete error (not just the first line)
- [ ] Searched the internet for the exact error text (if plausibly general)
- [ ] Inspected state with debugger or instrumentation
- [ ] Read the surrounding code and recent changes
- [ ] Stated a one-sentence hypothesis citing evidence
- [ ] Tested the hypothesis with a minimal change

Before claiming fixed:
- [ ] Wrote a regression test that fails without the fix
- [ ] Fixed at the source (not just where the error appeared)
- [ ] Regression test passes, full suite passes
</verification_checklist>

<integration>
**This skill calls:**
- `infinifu:domain-tdd` — write the failing regression test in phase 4
- `infinifu:domain-verification` — gate the "fixed" claim on real output
- `internet-researcher` agent — search for error messages
- `codebase-investigator` agent — map code structure
- `test-runner` agent — run tests without flooding your context

**This skill is called by:**
- `infinifu:domain-bug-fixing` — the full bd-tracked bug workflow uses phase 1–4 as its investigation step
</integration>

<references>
Load these when the situation calls for them — don't read them all preemptively.

- `references/root-cause-tracing.md` — backward-tracing technique when the bug is deep in the call stack
- `references/debugger-reference.md` — LLDB, GDB, and browser DevTools command recipes
- `references/defense-in-depth.md` — layering validation after the source fix
- `references/condition-based-waiting.md` — replacing arbitrary timeouts with polling (plus `condition-based-waiting-example.ts`)
- `references/find-polluter.sh` — binary-search for the test that leaks state
- `references/when-fixes-keep-failing.md` — what to do when three hypotheses in a row fail (usually: question the architecture)
</references>
