---
name: idea-hotfix
description: Use when the request is about a production-impacting bug in a shipped feature or implementation — "production is broken", "ft003 drops emails when the address has +alias", "us005 fails on payloads >1MB", "rollback X", "the metrics service is leaking memory", "we just got paged about Y". Routed to from `idea-brainstorming` when the entry type is *hotfix implementation or feature*. Captures the problem as `sp###.problem` with explicit urgency, blast radius, and rollback context — *no fix is written here*, only the problem definition.
---

# Idea: Hotfix (production bug)

## Overview

Specialized brainstormer for the "hotfix implementation or feature" entry type. A shipped feature or implementation is misbehaving in production. Capture severity, blast radius, and rollback options as `sp###.problem` — then hand to `spec-writing`.

**Announce at start:** "Using idea-hotfix skill to scope a production issue."

<HARD-GATE>
Do NOT fix the bug here. No code, no patch, no PR, no `bd update` to close anything. The hotfix urgency is real, but skipping the lifecycle creates undocumented behavior, leaves no ADR/feature trail, and makes the next regression worse. The fix lands via `spec-writing → spec-refinement → spec-ready → work-do`. This skill ends at `sp###.problem`.
</HARD-GATE>

## AKM hooks

Stage 1 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Entry type: **hotfix implementation or feature**.

**Reads:**

- `ft###` (via `feature-read`) — the affected feature(s). Read in full; the `## api_surface` and `## components` constrain what a fix can touch without widening the public contract.
- `us###` (via `story-read`) — the user-visible behavior that's broken. Read the AC; the fix must restore them.
- `im###` (via `implementation-read`) — the accepted implementation card. Read `## components` for the surface area the fix will touch.
- `cat###` (via `category-read`) — categories on the affected `im###` / `ft###`.
- `adr####` (via `adr-read --category <picks>`) — decisions that bind the affected categories. A hotfix that conflicts with an accepted ADR is a real cost; flag it.

**Writes:**

- `sp###` — new zettel at `docs/notes/spec/sp###.md`. Frontmatter `status: idea`, `Index: [[board]]`. Body: `## problem` documents symptom, severity, blast radius, rollback availability, and a one-paragraph minimal-fix shape (no patch — just shape).
- `docs/board.md` — append `[[sp###|<title>]]` under `## idea`. Annotate the entry with a 🔥 marker or `"hotfix"` prefix so the board surfaces urgency.

Urgency is raised on the **bd epic** the lifecycle creates downstream (P1/P0), not on the zettel. The zettel records the problem; bd records the schedule.

## Checklist

1. **Capture the symptom** — verbatim reproduction steps from the user, log lines, error messages. Do not fix yet; capture only.
2. **Identify the affected `ft###` / `im###` / `us###`** — via `feature-read`, `implementation-read`, `story-read`. The fix surface must be a known zettel; if none matches, the hotfix is touching un-tracked behavior — flag and capture as new `us###` after the fact.
3. **Severity** — pick: P0 (data loss / outage), P1 (significant customer impact), P2 (visible bug, workaround exists), P3 (cosmetic / edge case).
4. **Blast radius** — how many users affected, how often, is the bad state already in customer data, is the failure recoverable?
5. **Rollback** — is the previous version still deployable? Is rolling back safer than rolling forward? Note both.
6. **Survey binding ADRs** — `adr-read --category <picks>`. If the natural fix conflicts with an accepted ADR, flag it — that's a separate decision the user must own (file a new ADR at spec-retro time).
7. **One-paragraph minimal-fix shape** — describe the smallest change that restores the AC, in `sp###.problem`. No code; just shape.
8. **Present the captured problem to the user** — confirm severity / blast radius / minimal-fix-shape are right before minting the zettel.
9. **Mint `sp###`** — `## problem` carries severity / blast radius / rollback / minimal-fix-shape paragraph. Categories in H1 inherit from the affected `im###` / `ft###`.
10. **Update `docs/board.md`** under `## idea` with the urgency annotation.
11. **Hand off to `spec-writing`** — it will lock the patch shape and surface any necessary ADRs. Do not invoke `domain-bug-fixing` directly from here; the AKM lifecycle owns hotfixes too.

## Disambiguation

- **Not actually broken in prod, just an enhancement** → re-route to `idea-extend` (or `idea-implement` if no story exists).
- **Behavior is broken but no `ft###`/`im###`/`us###` exists for it** → file the discovery as a `us### draft` first via `story-write`, then continue here with the new id.
- **Capability-level regression spanning many implementations** → re-route to `idea-feature` (feature contract change).

## Key Principles

- **The lifecycle wins over urgency** — skipping spec-writing for hotfixes is what builds the next outage. The shape lands here; the patch lands downstream — fast, but in order.
- **Rollback is not a fix** — capture rollback as an option, but the `sp###.problem` still describes the forward fix shape so the team owns both directions.
- **ADR conflicts are not silent** — if the fix overturns an accepted decision, the user must see that cost before the patch ships.

## Integration

**Called by:** `infinifu:idea-brainstorming` (router) when entry type is *hotfix*.

**Calls:**

- `infinifu:feature-read` / `implementation-read` / `story-read` / `category-read` / `adr-read` — survey AKM context.
- `infinifu:spec-writing` — the only next step after the problem is captured. **Do not** invoke `domain-bug-fixing` directly; the lifecycle owns hotfix routing.
