---
name: story-write
description: Use when the user wants to create, add, or write a user story — captures a product requirement or backlog item in "as a... I want... because..." form and emits a new `docs/notes/us###.md` AKM zettel with frontmatter (aliases/status/created) and body sections (role/want/because/acceptance_criteria). This skill owns the Story schema (frontmatter shape, body, lifecycle); shared styling (atomicity, 80-char wrap, link discipline) is enforced by `infinifu:zettel-write`; `docs/notes/akm.md` carries only the top-level AKM model overview and lifecycle process flow. Also handles edits via re-emit with the same id (story content lives in the same file; refining a story is rewriting it). Invoke this whenever someone asks to "create a story", "add a story", "write a story", "new story", "make a backlog item", "log a requirement", "capture this as a user story", "revise story us013", or phrases a feature request from a user/persona perspective even if they don't say the word "story".
---

# Story Write

## Overview

Capture a single user story in Connextra format and write it as a new AKM zettel under `docs/notes/us###.md`. Stories are the product-level requirements that feed downstream Implementation zettels (`im###.md`) and bd epics. They describe **who** wants **what** and **why**, not how to build it.

**Storage backend:** AKM (Agentic Knowledge Model). This skill owns the Story schema (defined inline below under "Zettel Schema"). Top-level AKM model + lifecycle process flow live in `docs/notes/akm.md`; cross-type styling rules (atomicity, 80-char wrap, link discipline, post-write audit) live in `infinifu:zettel-write` and apply here.

**Announce at start:** "Using story-write skill to capture this as a user story."

## Process Flow

```dot
digraph story_create {
    "Resolve AKM root" [shape=box];
    "Storage exists?" [shape=diamond];
    "Bootstrap docs/notes/" [shape=box];
    "Gather Connextra fields" [shape=box];
    "Gather acceptance criteria" [shape=box];
    "Pick persona" [shape=box];
    "Gather H1 tags (optional)" [shape=box];
    "akm us write --stdin (allocates id, stages)" [shape=box];
    "Confirm with user" [shape=doublecircle];

    "Resolve AKM root" -> "Storage exists?";
    "Storage exists?" -> "Bootstrap docs/notes/" [label="no"];
    "Storage exists?" -> "Gather Connextra fields" [label="yes"];
    "Bootstrap docs/notes/" -> "Gather Connextra fields";
    "Gather Connextra fields" -> "Gather acceptance criteria";
    "Gather acceptance criteria" -> "Pick persona";
    "Pick persona" -> "Gather H1 tags (optional)";
    "Gather H1 tags (optional)" -> "akm us write --stdin (allocates id, stages)";
    "akm us write --stdin (allocates id, stages)" -> "Confirm with user";
}
```

## AKM Workspace Resolution

Stories are shared product knowledge and live on **main**, even when the
agent's cwd is a feature-branch worktree. Before any file operation, resolve
the AKM root:

```bash
AKM_ROOT="$(akm-root)"
```

`akm-root` returns the absolute path of the worktree on the project's
default branch (origin/HEAD → `main` → `master`). Outside a git repo it
falls back to the current directory.

Every path in this skill anchors on `$AKM_ROOT`:

- Zettel file: `$AKM_ROOT/docs/notes/us<NNN>.md`
- Hub file:    `$AKM_ROOT/docs/product.md`
- Persona list scan: `$AKM_ROOT/docs/notes/pn*.md`

If `akm-root` exits non-zero (no default-branch worktree), surface the
helper's stderr to the user and abort — don't silently write into the
feature worktree. The fix is for the user to either check out the default
branch or create a worktree (`git worktree add ../main main`).

**Why this matters.** Story-write is a `draft` artifact at this stage, so we
do not commit on main — we only **stage** the new file (`git -C "$AKM_ROOT"
add ...`). The commit happens later when `spec-writing` flips the story
`draft → ready`. Reading the story between draft and ready works because
the file is on disk in main's working tree; the staging entry just keeps it
visible in `git status` so it's not forgotten.

## Storage

**File:** one zettel per story at `$AKM_ROOT/docs/notes/us###.md` (three-digit
zero-padded id), resolved via the rule above.

If `$AKM_ROOT/docs/notes/` does not exist: create it. If `$AKM_ROOT/docs/product.md`
does not exist, the project is not AKM-set-up — warn the user "No
`docs/product.md` found in `$AKM_ROOT`; AKM workspace not initialized.
Create the hub manually or via the project's `epic-create` skill first."
then either proceed (zettel will reference a non-existent `[[product]]`)
or abort if the user prefers.

## Zettel Schema

Every story zettel has this exact shape:

```markdown
---
aliases:
  - <human-readable want clause / title>
status: <draft|ready|in_progress|done|dropped>
created: YYYY-MM-DD
---
# Story [[<flow-or-area>]] [[<theme>]] [[product]]

## role
[[pn###|<persona-alias>]]

## want
<want clause — one sentence>

## because
<motivation — one sentence>

## acceptance_criteria
- <criterion>
- <criterion>

---

Index: [[product]]
```

**Required pieces:**

- Frontmatter `aliases:` (at least one entry — the title), `status:`, `created:` (ISO date).
- H1 with at least `[[product]]` — additional flow/theme tag wikilinks are optional.
- `## role`, `## want`, `## because`, `## acceptance_criteria` sections.
- `Index: [[product]]` footer.

**Lifecycle status values:**

| Status | Meaning |
|--------|---------|
| `draft` | captured, not refined — acceptance criteria may be incomplete |
| `ready` | refined, sized, ready for spec-writing |
| `in_progress` | bd epic exists and is being worked |
| `done` | merged — Implementation card carries the bd-epic link |
| `dropped` | abandoned — keep file for history; mark status, no delete |

New stories default to `draft`.

## ID Generation

IDs are `us` + three-digit zero-padded sequential (`us001`, `us002`, …). Not date-bucketed — the AKM model uses pure sequential ids so wikilinks like `[[us001]]` stay stable forever.

**The CLI owns id allocation** — `akm us write` takes the max numeric portion of existing `us*.md` files + 1, zero-padded to 3 digits, gaps never reused (a dropped `us003` stays a gap). You don't compute the id; you capture it from the `Id: us###` first line of the CLI's stdout. The detail here is just so you understand what the returned id means.

## Gathering Story Content

Stories are small. Don't over-interview the user. The goal is to capture what they have in mind, not to brainstorm the feature.

**If the user provided everything upfront** (full role/want/because/criteria in one message): write the story, don't ask anything, just confirm at the end.

**If fields are missing**: ask only for the missing pieces, one focused question per turn. Use AskUserQuestion when there are 2-4 plausible options (e.g., persona choices), free-text when open-ended.

**Connextra phrasing** — the final story should compose into this grammatical sentence:

> As a `<persona-alias>`, I want `<want>`, because `<because>`.

If the three pieces don't compose into a grammatical sentence, the fields are wrong — push back once.

**Examples:**

Good:
- persona: `requestor` (`pn001`), want: `order samples for upcoming client work`, because: `I need product in hand for client tasting`
- persona: `approver` (`pn002`), want: `approve or reject a submitted request`, because: `the warehouse should only pick approved orders`

Bad (vague persona):
- persona: `user`, want: `the app to be fast`, because: `it's better`

## Picking the Persona

The `## role` field is a wikilink `[[pn###|<persona-alias>]]` to a persona zettel under `$AKM_ROOT/docs/notes/pn###.md`.

**Lookup workflow:**

1. List existing personas: `ls "$AKM_ROOT/docs/notes/"pn*.md` (or in-process equivalent).
2. For each, read the frontmatter `aliases:` — the first alias is the canonical short label (e.g. `requestor`, `approver`).
3. **If the user named a persona that matches an existing alias** (case-insensitive substring or exact), use that `pn###` id.
4. **If no persona matches**, ask the user: "No existing persona matches `<name>`. Pick from: <list of existing aliases>, or describe a new one (I'll create the `pn###` zettel)."
5. **If they want a new persona**, write a minimal `pn###.md` per the AKM Persona schema (status `draft`, just `## name` and `## summary`) — that's outside the scope of this skill but cheap to inline.

The wikilink form is `[[pn001|requestor]]` — `pn001` is the file slug, `requestor` is the alias label that renders in `story-read`. Use the first alias from the persona's frontmatter as the label.

## Acceptance Criteria

Each criterion must be (a) objectively testable AND (b) phrased in **problem-space, not solution-space**. Testable means a tester can read it and know whether it passes or fails. Problem-space means it describes *what the user or system does* (observable behavior), not *how the developer builds it*.

**Good (testable + problem-side):**
- "browse catalog of available samples"
- "rejected request can be reopened from the rejected view"
- "preview parsed rows before commit and reject bad rows with row-level error messages"

**Bad — not testable:**
- "Works well" — subjective
- "Users like the feature" — subjective
- "Handles edge cases" — vague

**Bad — solution-side leakage** (testable, but prescribes the implementation):
- "Add a `Clone` button to the request detail view" — imperative on the developer
- "POST `/api/requests/{id}/clone` returns `201` with the new id" — pre-commits a REST contract
- "Use the React `useFormState` hook in `CloneRequestForm.tsx`" — names files, frameworks
- "Add `cloned_from_id` foreign key to `requests` table" — pre-commits the schema
- "Implement validation in middleware" — reads like a dev task, not a behavior

If the user gives only one vague criterion, push back once: "Can you add 1-2 more criteria covering [edge case / failure mode / boundary]?" Don't fabricate criteria they didn't ask for.

### Problem-side, not solution-side

The story is a *problem statement*. The AC sharpen the problem; they do not commit to a solution. Pre-committed solutions in AC are the most common rot pattern in user stories — they accidentally lock the design before `spec-writing` has a chance to weigh alternatives (queue vs API vs UI-only duplicate vs background job, etc.). Keep AC in problem-space and the spec phase preserves design optionality.

**Signals that a criterion has drifted into solution-mode** — and how to reframe each:

| Signal | Example (solution-side) | Reframe (problem-side) |
|---|---|---|
| Imperative verb on the developer (`add`, `create`, `implement`, `build`, `use`) | "Add a `Clone` button to the request detail view" | "User can duplicate a closed request from its detail view" |
| Names an API endpoint, route, HTTP verb, or status code | "`POST /api/clone` returns `201` with the new id" | "Cloning produces a new draft request linked to the original" |
| Names a framework, library, file path, or component | "Use the React `useFormState` hook in `CloneRequestForm.tsx`" | "Cloning preserves all line items but clears the notes field" |
| Names a database table, column, index, or schema | "Add `cloned_from_id` foreign key to `requests` table" | "Each cloned request remembers which request it came from" |
| Reads like a ticket on a dev's task list | "Implement validation in middleware" | "Submitting a cloned request fails fast if any line item is unavailable" |

The subject of a problem-side AC is almost always the **user / persona / system observable to the user** — not the developer or the codebase.

**When the user supplies solution-shaped AC** (e.g. they pasted in implementation notes): do **not** silently rewrite — they wrote what they wrote, and they may be constrained by an external contract you can't see. Instead:

1. Write the story with their wording intact.
2. In the confirmation step, flag each solution-leaking bullet with a one-line note:
   > *"AC #N reads as a solution (`add X button`). Spec-writing decides HOW; want me to rephrase as observable behavior, or keep as-is?"*
3. If they say "rephrase", reword inline and re-show. If they say "keep", leave it. Always ask before changing user-supplied wording.

**When you derive AC** (user gave none, see the "Zero Acceptance Criteria" subsection below): stay strictly problem-side from the start. Don't invent imperative dev tasks. Use the role + want + because to extract observable behaviors only — entry point, success path, edge case, failure mode.

**When the user's `want` itself is solution-shaped** (e.g. "I want a Clone button on the detail view"): that's a different problem — the *want* should describe an outcome, not a UI element. Push back once: *"That phrasing is the solution. What's the underlying need? Try: 'I want to duplicate a previous request so I don't have to retype identical orders.'"* If they decline, accept their wording — the rule about preserving user phrasing wins.

### When the User Gives Zero Acceptance Criteria

If the user provides **no acceptance criteria at all** (want/because present but no testable bullets):

1. **Preferred:** ask once — "Any acceptance criteria? 1-3 testable bullets that would let us know it's done."
2. **If asking is not possible** (non-interactive mode, user's message is the whole input): derive 2-4 baseline criteria from the `want` and `because` covering obvious boundaries (entry point, success path, expiry/timeout, error case). **Then explicitly flag this in your confirmation:** "You didn't specify acceptance criteria, so I derived N covering [areas]. Confirm or revise."

Never silently invent criteria. The user must always know which bullets came from them and which came from you.

## H1 Tag Wikilinks (optional)

The H1 carries `[[product]]` plus optional flow/theme tag wikilinks for grouping in the hub:

```markdown
# Story [[requestor-flow]] [[catalog]] [[product]]
```

These are **optional** and **may dangle** — `[[requestor-flow]]` is fine even without a backing `requestor-flow.md` zettel. The moxide LSP will flag dangling links as diagnostics; users tolerate them when the tag is conceptual.

**Tag selection is delegated to the `tag-manage` skill** (suggest mode). That skill owns the canonical taxonomy + synonym map.

**How to use it from here:**

1. Invoke `tag-manage` in suggest mode with the draft story's role/want/because/criteria as input.
2. It returns 1-4 suggested tags as bare wikilink targets (e.g. `requestor-flow`, `catalog`).
3. Pass them to `akm us write` via `--tags requestor-flow,catalog` (comma-separated, no brackets) — the CLI renders them as `[[<tag>]]` before `[[product]]` in the H1.
4. **If the user did not explicitly specify tags, flag in your confirmation** which tags came from the suggester. Same derivation-flag rule as for acceptance criteria.

**If the user explicitly listed tags in their message** (e.g. "tag this with requestor-flow and catalog"), use them verbatim — skip the suggester. tag-manage's `add` mode is for after-the-fact tagging.

**If tags are not relevant** (e.g. a one-off cross-cutting story), it's fine to write just `# Story [[product]]` with no tag wikilinks. The story-read skill handles the no-tag case.

## Writing the Zettel

Pipe the composed body (the four `## role / ## want / ## because /
## acceptance_criteria` sections only — no frontmatter, no H1, no footer) to
the typed writer, which allocates the id, writes frontmatter + the tagged
`# Story [[tag]]... [[product]]` H1 + footer, and stages the file on main:

```bash
printf '## role\n[[%s|%s]]\n\n## want\n%s\n\n## because\n%s\n\n## acceptance_criteria\n%s\n' \
  "$pn_id" "$persona_alias" "$want" "$because" "$criteria_bullets" \
  | akm us write "$slug" --tags requestor-flow,import --stdin
```

- `$slug` is the **first alias as a kebab-case slug** (letters/digits/dash/
  underscore only — the CLI rejects spaces and prose). It becomes
  `aliases[0]`. If the natural title has spaces, slugify it for the argument;
  the human-readable title can be refined in the file afterward if needed.
- `--tags` takes the optional H1 tag slugs (comma-separated, arbitrary, may
  dangle). Omit it for a tagless `# Story [[product]]`.
- The `## role` body line holds the `[[pn###|alias]]` persona link (see
  "Picking the Persona"); the CLI does not resolve personas — you compose
  that line into the piped body.
- Capture the allocated id from the `Id: us###` first line of stdout.

The CLI owns id allocation, frontmatter, the H1, the `Index: [[product]]`
footer, and `git add`. Do **not** hand-write the file. If the alias already
exists the CLI short-circuits without overwriting — treat that as a revision
and edit the existing file in place instead.

Do **not** commit at this stage — `story-write` produces a `draft` artifact.
`spec-writing` (the next lifecycle skill) commits the accumulated AKM changes
when the story flips `draft → ready`. See "Workspace Resolution" in
`docs/notes/akm.md` for the full per-stage commit policy.

**Example output for a fresh story:**

`$AKM_ROOT/docs/notes/us014.md`:

```markdown
---
aliases:
  - bulk import requests from spreadsheet
status: draft
created: 2026-05-14
---
# Story [[requestor-flow]] [[import]] [[product]]

## role
[[pn001|requestor]]

## want
upload a spreadsheet to create many requests at once

## because
event prep means submitting dozens of similar requests and the per-row UI is slow

## acceptance_criteria
- accept .xlsx and .csv uploads
- each row maps to one request with line items
- preview parsed rows before commit and reject bad rows with row-level error messages

---

Index: [[product]]
```

**Conventions:**

- ISO `YYYY-MM-DD` for `created`.
- One alias entry (the title) is the minimum; add more aliases only if the user gave multiple equivalent phrasings.
- Persona wikilink form: `[[pn###|alias]]` — pipe-separated, alias label after.
- H1 tag wikilinks are bare slugs in double brackets, no pipe label needed.
- Body sections must be `## role`, `## want`, `## because`, `## acceptance_criteria` exactly — `story-read` parses on these headings.
- Footer is a `---` rule then `Index: [[product]]` on its own line.

## Updating `$AKM_ROOT/docs/product.md` (the hub)

The hub groups stories under `## Stories` by persona. After writing the new story, append a wikilink to it under the right persona heading. If the persona section doesn't yet exist in the hub, add it. Example diff:

```markdown
## Stories

### [[pn001|requestor]]

- [[us001|order samples for upcoming client work]]
- [[us014|bulk import requests from spreadsheet]]    ← new
```

The hub wikilink form is `[[us###|<title>]]` — pipe-separated, with the alias/title as the label for readability.

If `$AKM_ROOT/docs/product.md` doesn't exist, skip the hub update and tell the user "Hub `docs/product.md` not found in `$AKM_ROOT`; new story is on disk but not linked from the hub. Create the hub when ready."

## Confirmation

After writing, show the user:

1. The story id and the absolute file path (`$AKM_ROOT/docs/notes/us<NNN>.md`) — surface the resolved AKM root so the user sees where the file landed when invoked from a worktree.
2. The full Connextra sentence: "As a `<persona-alias>`, I want `<want>`, because `<because>`."
3. Acceptance criteria as a bulleted list.
4. Tags rendered in the H1 (and a note if any came from the suggester).
5. Whether the hub was updated.

Ask once: "Anything to revise?" If yes, edit the zettel in place (same id). If no or no response, you're done.

## What This Skill Does NOT Do

- It does not plan implementation. That's `spec-writing`.
- It does not create the matching `im###.md` Implementation zettel — that happens at spec time, before code lands.
- It does not create bd tasks/epics. That's `spec-ready`.
- It does not estimate, prioritize, or assign.
- It does not silently refine vague stories into INVEST-compliant ones. The user's wording is preserved; you may suggest improvements but do not silently rewrite.
- It does not touch any other zettel type (`pn###`, `ft###`, `im###`, `adr####`, `cat###`) except optionally creating a missing persona (see "Picking the Persona") and updating the hub.

## When to Defer to Other Skills

- User wants a full design discussion → `idea-brainstorming`.
- User wants to turn an approved story into a build plan → `spec-writing`.
- User wants to read / list / find existing stories → `story-read`.
- User wants to add tags to an existing story → `tag-manage` (add mode).
- User wants to map code paths to a story → `story-map`.
