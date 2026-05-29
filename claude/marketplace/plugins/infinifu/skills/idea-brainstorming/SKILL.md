---
name: idea-brainstorming
description: "Shared brainstorming basics referenced by `infinifu:idea-implement` / `idea-extend` / `idea-feature` / `idea-hotfix` — the project-context exploration, hard-gate enforcement, one-question-at-a-time cadence, and design-approval flow that every entry type follows. Not a direct entry point; the four entry-type skills above are what triggers on user requests. Load this when an entry skill says 'see idea-brainstorming for shared basics'. If a request genuinely fits none of the four entry skills, ask one MC question to identify the type and route there — never run this skill standalone."
---

# Brainstorming Basics (shared)

## Overview

Shared process content for the four AKM entry-type brainstormers. Each entry skill (`idea-implement`, `idea-extend`, `idea-feature`, `idea-hotfix`) triggers directly on user phrasing per its own description. They share the process below — the hard gate, the context exploration, the question cadence, the design-approval rhythm — so the four don't drift.

This skill is **not a router** and not a direct entry point. It's the shared-content vault the four entry skills load.

## The Hard Gate (every entry type)

<HARD-GATE>
Do NOT invoke any implementation skill, write any code, scaffold any project, create bd issues, or take any implementation action until you have presented a design and the user has approved it. This applies to every entry type, every project, regardless of perceived simplicity. The gate is what makes the lifecycle worth the cost — skipping it builds undocumented behavior and the next outage.
</HARD-GATE>

## Anti-Pattern: "This Is Too Simple"

Every request goes through the lifecycle. A todo list, a one-line config change, a typo fix — all of them. "Simple" requests are where unexamined assumptions cause the most wasted work. The downstream design can be short for truly simple cases, but the entry type must be picked and a design must be presented.

## AKM Workspace Resolution

Specs (`sp###`) and the board live on **main**, even when the agent's cwd
is a feature-branch worktree. Before any file operation in stage 1,
resolve the AKM root:

```bash
AKM_ROOT="$(akm-root)"
```

`akm-root` returns the absolute path of the worktree on the project's
default branch (origin/HEAD → `main` → `master`). Outside a git repo it
falls back to cwd. Every path in this skill and the four entry skills
anchors on `$AKM_ROOT`:

- Spec zettel: `$AKM_ROOT/docs/notes/spec/sp<NNN>.md`
- Board hub:   `$AKM_ROOT/docs/board.md`
- AKM reads:   `$AKM_ROOT/docs/notes/...` (us / pn / ft / im / adr / cat)

If `akm-root` errors (no default-branch worktree), surface the helper's
stderr and abort — never silently land an idea on the feature branch.

**Commit policy: stage only at the idea stage.** Per the per-stage
table in `docs/notes/akm.md#workspace-resolution`, writes during
exploratory or draft phases stay staged-only. The first commit on main
for the idea→spec lineage happens at `spec-writing` when the idea
graduates to a spec. At idea time:

```bash
git -C "$AKM_ROOT" add docs/notes/spec/sp<NNN>.md docs/board.md
# DO NOT commit — spec-writing carries the first commit
```

## Process (every entry type)

### 1. Resolve AKM root

Run `AKM_ROOT="$(akm-root)"` once at the top of the session. Anchor every
subsequent path on `$AKM_ROOT`. If the helper errors, surface stderr and
abort — see `## AKM Workspace Resolution` above.

### 2. Explore project context

- Read README, recent commits, and the directly-affected paths (e.g. `src/services/<x>/` for a service-level change).
- Read what's needed to ground the proposal — not everything.

### 3. Survey AKM context (entry-specific)

Each entry skill's `## AKM hooks` block lists the read set. Survey concretely via the read skills (`category-read`, `adr-read`, `feature-read`, `story-read`, `persona-read`, `implementation-read`) — never invent zettel ids that don't exist. All read skills resolve `$AKM_ROOT/docs/notes/...` themselves; you don't need to pass paths.

**Grounding rule.** Every "we could use X" mentioned in the proposal is anchored to a real zettel id surfaced by a read skill. If a candidate doesn't exist yet, say so explicitly ("no existing ft### covers this; we'd mint one at spec-writing").

### 4. Ask clarifying questions

- **One question per message.** Don't overwhelm.
- **Multiple-choice preferred.** Three options or fewer.
- Cover the entry-specific essentials (persona / want / because / AC for `idea-implement`; AC delta and migration story for `idea-extend`; capability boundary and consumers for `idea-feature`; severity / blast radius / rollback for `idea-hotfix`).

### 5. Propose 2-3 design approaches

- Lead with your recommended option.
- Each option carries trade-offs.
- Anchor every option in the surveyed AKM context (which categories, which ADRs constrain, which features are candidates).

### 6. Present the design, get approval

- Section by section, scaled to complexity (a few sentences for simple, up to 200-300 words for nuanced).
- Confirm after each section before continuing.
- Be ready to revise.

### 7. Mint the zettel(s)

Per the entry skill's `## AKM hooks` write set. The common write across all
four is the `sp###`, minted through the typed CLI so id allocation,
frontmatter, the categorized H1, the `Index: [[board]]` footer, the board
`## idea` registration, and staging all happen in one place:

```bash
printf '## problem\n%s\n' "$problem_body" \
  | akm sp write "$title-slug" --category cat003,cat006 --stdin
# add --session to mint a claude_session_id + get a resume command back
```

- `$title-slug` is a **kebab-case slug** (letters/digits/dash/underscore
  only — the CLI rejects spaces or prose); it becomes `aliases[0]`.
- `--category` takes the proposed `[[cat###]]` picks (one or more,
  comma-separated) — the H1 becomes `# Spec [[cat###]]... [[board]]`.
- Capture the allocated id from the `Id: sp###` first line of stdout.
- The CLI registers `[[sp###|<title>]]` under `docs/board.md ## idea` and
  stages both files. Do **not** hand-write the spec file or edit board.md
  directly.

Entry-specific writes (new `us###`, new `pn###`, severity annotation, etc.)
live in the entry skill — those use their own typed writers (`akm pn
write`, etc.) or, where no typed writer exists yet, a staged write.

### 8. Stage on main

The `akm sp write` call already staged the spec + board.md. Stage any
entry-specific paths the entry skill wrote (`git -C "$AKM_ROOT" add ...`).
Do **not** commit — `spec-writing` handles the first commit when the idea
graduates to a spec. See the per-stage table in
`docs/notes/akm.md#workspace-resolution`.

### 9. Hand off to spec-writing

The only next step. Do **not** invoke any implementation skill (`work-do`, `domain-bug-fixing`, etc.) directly from any entry-type brainstormer. Confirmation to the user should surface the absolute path under `$AKM_ROOT` so the user sees where the spec landed when invoked from a worktree.

## Key Principles

- **One question at a time.**
- **Multiple-choice preferred.**
- **Survey before proposing.** Never invent category / ADR / feature / story ids.
- **YAGNI ruthlessly.** Trim non-essential scope.
- **Incremental validation.** Approval per section.
- **The hard gate is non-negotiable.** No exception for "simple", no exception for hotfix urgency.

## Process flow

```dot
digraph brainstorm_basics {
    "Resolve AKM root" [shape=box];
    "Explore project context" [shape=box];
    "Survey AKM context (entry-specific)" [shape=box];
    "Ask one clarifying question" [shape=box];
    "Have enough?" [shape=diamond];
    "Propose 2-3 approaches" [shape=box];
    "Present design sections" [shape=box];
    "User approves?" [shape=diamond];
    "Mint sp### + entry-specific writes" [shape=box];
    "Stage on main (no commit)" [shape=box];
    "Hand off to spec-writing" [shape=doublecircle];

    "Resolve AKM root" -> "Explore project context";
    "Explore project context" -> "Survey AKM context (entry-specific)";
    "Survey AKM context (entry-specific)" -> "Ask one clarifying question";
    "Ask one clarifying question" -> "Have enough?";
    "Have enough?" -> "Ask one clarifying question" [label="no"];
    "Have enough?" -> "Propose 2-3 approaches" [label="yes"];
    "Propose 2-3 approaches" -> "Present design sections";
    "Present design sections" -> "User approves?";
    "User approves?" -> "Present design sections" [label="no, revise"];
    "User approves?" -> "Mint sp### + entry-specific writes" [label="yes"];
    "Mint sp### + entry-specific writes" -> "Stage on main (no commit)";
    "Stage on main (no commit)" -> "Hand off to spec-writing";
}
```

## Integration

**Loaded by (not invoked from):**

- `infinifu:idea-implement`
- `infinifu:idea-extend`
- `infinifu:idea-feature`
- `infinifu:idea-hotfix`

**Not a direct entry point.** If a user request truly doesn't fit any of the four entry types, ask one MC question to identify the type before routing — never run this skill standalone.

**Next skill in chain (every entry type):** `infinifu:spec-writing`.
