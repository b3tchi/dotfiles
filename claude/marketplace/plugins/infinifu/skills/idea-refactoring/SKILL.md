---
name: idea-refactoring
description: Use when identifying bad code/design and selecting refactor targets - produces a diagnosis report with smells, risks, design direction, and refactor vs rewrite decision
---

<skill_overview>
Entry point for refactoring: diagnose smells and traps with evidence, assess risk, choose target design patterns, and decide refactor vs rewrite. This is the "idea" stage for the refactor scenario — it produces the input for spec-writing and spec-refinement.
</skill_overview>

<rigidity_level>
MEDIUM FREEDOM — the required outputs and evidence standards are strict because refactor decisions that skip evidence turn into "I have a feeling this is bad" and get over-ruled the first time a deadline appears. Analysis depth and tooling adapt to the codebase.
</rigidity_level>

<quick_reference>
| Step | Action | Deliverable |
|------|--------|-------------|
| 1 | Define scope and constraints | Scope statement |
| 2 | Gather evidence (code, tests, runtime behavior) | Evidence notes |
| 3 | Map evidence to smells/traps | Smell table |
| 4 | Assess risk and impact | Risk matrix |
| 5 | Decide refactor vs rewrite | Decision + rationale |
| 6 | Produce diagnosis report | Required report format |
</quick_reference>

<when_to_use>
- You want to identify bad code/design and decide what to refactor
- You keep seeing recurring issues (deadlocks, regressions, fragile tests)
- You need a defensible, prioritized refactor target list
- You must decide between refactor vs rewrite
</when_to_use>

<the_process>
## 1. Define Scope (No Vague Targets)
State the specific module/component/system boundary you are diagnosing and what is out of scope.

## 2. Gather Evidence
Minimum evidence sources:
- Read relevant production code paths
- Read tests or lack thereof
- Identify entrypoints and call chains
- Note any concurrency/IPC boundaries

## 3. Map to Smells/Traps (Evidence Required)
Use the catalogs in references:
- `references/smell-catalog.md`
- `references/test-smells.md`
- `references/concurrency-ipc-traps.md`

For each smell/trap, cite concrete evidence (file path, function, behavior).

## 4. Assess Risk and Impact
Classify each smell by:
- Severity (low/med/high)
- Change risk (low/med/high)
- Blast radius (local/module/system)
- Recurrence likelihood

## 5. Refactor vs Rewrite Decision
Rules of thumb:
- If tests are absent and behavior is unknown → write characterization tests before refactor
- If 3+ refactor attempts failed or behavior is unstable → consider rewrite
- If change risk is high and scope is large → split into smaller refactors

## 6. Produce Diagnosis Report (Required Format)
Use this exact structure:

```
## Scope
- In scope:
- Out of scope:
- Constraints:

## Evidence
- Files reviewed:
- Entry points:
- Tests reviewed:
- Concurrency/IPC boundaries:

## Smells and Traps (Evidence-Backed)
| Smell/Trap | Evidence | Risk | Suggested Refactor Direction |

## Test Smells
| Test Smell | Evidence | Risk | Suggested Fix |

## Concurrency/IPC Traps
| Trap | Evidence | Risk | Suggested Fix |

## Risk Assessment
- Highest risk areas:
- Largest blast radius:
- Most likely regression vectors:

## Refactor vs Rewrite Decision
- Decision:
- Rationale:

## Top Refactor Targets (Prioritized)
1.
2.
3.

## Non-goals
- 

## Open Questions
- 
```

## 7. Design Direction

After diagnosis, outline the refactor design direction:

**Target structure:**
- What components/modules will exist after refactoring
- Composition boundaries and responsibilities

**Refactor patterns:** Use `references/patterns-and-choices.md` to select patterns that address diagnosed smells.

**DI seams:** Use `references/type-driven-design.md` for:
- What dependencies become interfaces
- How they are injected (constructor, factory, parameter)

**Test strategy:** What tests verify the refactor preserves behavior (happy paths, error paths, concurrency).

## 8. Transition to Spec

After diagnosis + design direction:
- Invoke `spec-writing` to formalize into an implementation spec
- `spec-refinement` reviews the spec
- `spec-ready` creates tasks with deps and parallelism, promotes spec to `board/ready/`
- `domain-refactor-safely` executes the refactor

</the_process>

<common_rationalizations>
## Common Excuses
All of these mean: stop and complete diagnosis first.
- "We already know what's wrong"
- "Time pressure, just fix it"
- "We can refactor as we go"
- "It's just cleanup"
- "I can't access the references or skill file" (proceed with required format and note assumptions)
</common_rationalizations>

<red_flags>
- Starting implementation without a diagnosis report
- No evidence cited for smells/traps
- Mixing bug fixes with refactoring goals
- Skipping concurrency/IPC analysis in concurrent systems
</red_flags>

<integration>
**Called by:**
- infinifu:meta-bootstrap (router) — when refactoring work is detected

**Calls:**
- infinifu:spec-writing — to formalize the diagnosis + design into an implementation spec

**Call chain:**
```
idea-refactoring → spec-writing → spec-refinement → spec-ready → plan-dispatch → domain-refactor-safely → done
```
</integration>
