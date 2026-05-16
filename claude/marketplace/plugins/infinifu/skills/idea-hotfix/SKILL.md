---
name: idea-hotfix
description: "You MUST use this when the request is about a production-impacting bug in a shipped feature or implementation — 'production is broken', 'ft003 drops emails when the address has +alias', 'us005 fails on payloads >1MB', 'rollback X', 'the metrics service is leaking memory', 'we just got paged about Y', or any phrasing that conveys urgency from a real production incident. Direct entry point for AKM lifecycle stage 1, *hotfix implementation or feature* entry type. Captures the problem as `sp###.problem` with explicit severity, blast radius, and rollback context — *no fix is written here*, only the problem definition. Loads shared brainstorming basics from `infinifu:idea-brainstorming`."
---

# Idea: Hotfix (production bug)

## Overview

Direct entry point for the "hotfix implementation or feature" entry type. A shipped feature or implementation is misbehaving in production. Capture severity, blast radius, and rollback options as `sp###.problem` — then hand to `spec-writing`.

**Announce at start:** "Using idea-hotfix skill to scope a production issue."

**Shared basics.** Process (context exploration, hard gate, question cadence, design approval, spec-writing handoff) lives in `infinifu:idea-brainstorming`. Load it before walking the checklist below.

<HARD-GATE>
Do NOT fix the bug here. No code, no patch, no PR, no `bd update` to close anything. The hotfix urgency is real, but skipping the lifecycle creates undocumented behavior, leaves no ADR/feature trail, and makes the next regression worse. The fix lands via `spec-writing → spec-refinement → spec-ready → work-do`. This skill ends at `sp###.problem`. The shared `idea-brainstorming` hard gate applies in full; the urgency-bypass temptation is the reason this skill needs its own explicit reminder.
</HARD-GATE>

## AKM hooks

Stage 1 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Entry type: **hotfix implementation or feature**.

**Reads:**

- `ft###` (`feature-read`) — affected feature(s). `## api_surface` and `## components` constrain what a fix can touch without widening the public contract.
- `us###` (`story-read`) — user-visible behavior that's broken. The fix must restore the AC.
- `im###` (`implementation-read`) — accepted implementation card. `## components` is the surface area the fix will touch.
- `cat###` (`category-read`) — categories on the affected `im###` / `ft###`.
- `adr####` (`adr-read --category <picks>`) — decisions binding the affected categories. A hotfix that conflicts with an accepted ADR is a real cost; flag it.

**Writes:**

- `sp###` — new zettel at `docs/notes/spec/sp###.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body: `## problem` documents symptom, severity, blast radius, rollback availability, and a one-paragraph minimal-fix shape (no patch — just shape).
- `docs/board.md` — append `[[sp###|<title>]]` under `## idea`. Annotate with a 🔥 marker or `"hotfix"` prefix so the board surfaces urgency.

Urgency is raised on the **bd epic** created downstream (P1/P0), not on the zettel. The zettel records the problem; bd records the schedule.

## Entry-specific checklist

1. **Capture the symptom verbatim.** Reproduction steps, log lines, error messages. Don't fix; capture only.
2. **Identify affected `ft###` / `im###` / `us###`** via the read skills. No match → fix is touching un-tracked behavior; file as new `us###` draft after the fact.
3. **Severity.** Pick: P0 (data loss / outage), P1 (significant customer impact), P2 (visible bug, workaround exists), P3 (cosmetic / edge case).
4. **Blast radius.** How many users, how often, is bad state already in customer data, is the failure recoverable?
5. **Rollback.** Is the previous version still deployable? Is rolling back safer than rolling forward? Note both.
6. **Survey binding ADRs.** `adr-read --category <picks>`. Natural-fix conflicts with an accepted ADR → flag for spec-retro to file a new ADR.
7. **Minimal-fix shape.** One paragraph in `sp###.problem`. Describe smallest change that restores AC. No code; just shape.
8. **Confirm captured problem with user** before minting the zettel.
9. **Mint `sp###`** with all of the above in `## problem`.
10. **Update `docs/board.md`** under `## idea` with the urgency annotation.

Walk the shared process around this checklist.

## Disambiguation

- **Not actually broken in prod, just an enhancement** → re-route to `idea-extend` (or `idea-implement` if no story exists).
- **Behavior broken but no `ft###` / `im###` / `us###` covers it** → file the discovery as a `us### draft` first via `story-write`, then continue here with the new id.
- **Capability-level regression spanning many implementations** → re-route to `idea-feature` (feature contract change).

## Key Principles (entry-specific)

- **The lifecycle wins over urgency.** Skipping spec-writing for hotfixes is what builds the next outage. Shape lands here; patch lands downstream — fast, but in order.
- **Rollback is not a fix.** Capture as an option, but `sp###.problem` still describes the forward fix shape.
- **ADR conflicts are not silent.** If the fix overturns an accepted decision, the user must see that cost before the patch ships.

## Integration

**Calls:**

- `infinifu:feature-read` / `implementation-read` / `story-read` / `category-read` / `adr-read` — AKM context survey.
- `infinifu:idea-brainstorming` — shared process basics.
- `infinifu:spec-writing` — the only next step. Do **not** invoke `domain-bug-fixing` directly; the lifecycle owns hotfix routing.
