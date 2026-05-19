# persona-write — worked examples

Three end-to-end walkthroughs and the deep prose behind the load-bearing rules. Load this when the SKILL.md skeleton isn't enough — typically when (a) you need to see how a session plays out, (b) you're about to rename an alias, or (c) you're flipping status and want the full rationale.

## Schema reproduction (for offline reference)

Canonical source is `docs/notes/akm.md#persona--pnmd`. Reproduced here so you don't have to round-trip when the workspace's AKM file isn't loaded:

```markdown
---
aliases:
  - <canonical short label, e.g. requestor>
status: <draft|validated|retired>
created: YYYY-MM-DD
---
# Persona [[product]]

## name
<full role name, e.g. Field Sales Rep>

## summary
<one paragraph: who, where, why they touch the system>

## primary_goals
- <goal>
- <goal>

## open_questions
- <unresolved discovery question>

---

Index: [[product]]
```

**Required pieces:**

- Frontmatter `aliases:` (≥ 1 entry — the canonical short label), `status:`, `created:` (ISO).
- H1 is exactly `# Persona [[product]]`. Personas are a supporting type; they don't get their own `[[product]]` section, so there's nothing for an H1 tag to group under.
- `## name`, `## summary`, `## primary_goals`, `## open_questions` sections in that order.
- `Index: [[product]]` footer.

New personas default to `status: draft`. Flip to `validated` only when `## open_questions` is empty (or migrated to an ADR / decision log).

## The first alias is load-bearing

The first entry in `aliases:` is what every story will use as its label inside `[[pn001|requestor]]`. Two consequences ripple from that fact:

**Kebab-case, short, role-shaped.** `requestor`, `approver`, `field-sales-rep`, `warehouse-approver`. Not full sentences, not titles, not `Field Sales Rep` with capitals — the alias renders inside `[[…|alias]]` in story bodies and in the hub's `## Stories` H3 subheadings. Title case looks wrong in both contexts and the hub generators don't normalize it.

**Stable once chosen.** Changing `aliases[0]` later renames the label on every story that references this persona. Mechanically possible (re-emit each story via `story-write` with the new label) but expensive in a backlog of any size. Push back once if the user proposes something vague (*"user"*, *"actor"*) or something that will obviously shift (*"v2-requestor"*).

Subsequent aliases (`aliases[1..]`) are free aliases — synonyms the user might search for. Add them when the user gave multiple equivalent phrasings; otherwise leave the list at one entry. They have no rename cost because nothing links via them.

## Status lifecycle — full rationale

| Status | Means | When to use |
|--------|-------|-------------|
| `draft` | Captured, but `## open_questions` still populated | The common case — most new personas |
| `validated` | `## open_questions` empty (or moved to ADR / decision log) | After enough stories reference this persona that the role is well-understood |
| `retired` | Role no longer served | Add a `## retired` body section with date + reason; keep all existing story back-links — they're history, not live links |

**Why `draft` is the default and not a problem.** Most personas are captured while discovery is still ongoing. Forcing `validated` at write time encourages either (a) inventing answers to look complete, or (b) waiting to register the persona until everything is known — and then stories can't link to it. The point of `draft` is to let the persona exist *now* with honest gaps, so the backlog can grow against it.

**Why personas don't supersede in place.** Unlike ADRs / Features / Implementations — which are append-only because they record decisions — personas are just role descriptions. If the role itself genuinely splits (one persona becomes two distinct ones) or merges (two personas turn out to be the same), retire the old `pn###` and create new ones, then re-emit the affected stories with updated `role` links. No `## superseded_by` field on personas; the lineage lives in commit history and the `## retired` section.

**Why retired files stay.** Existing stories referenced this persona. Deleting `pn###.md` would dangling-break every one of those wikilinks (moxide `unresolved_diagnostics = true` will surface them). The file is history; the wikilinks are read-only pointers into that history.

## Example 1 — fresh persona with open questions

**Input:**

> *"We need a persona for the warehouse approver. They sit in the back office, review submitted sample requests, and approve or reject them before the pick list goes out. Not sure yet whether one approver covers all regions or whether we'll have regional approvers."*

**Atomicity check.** One role, one summary, clear primary goals, one open question. ✓

**Alias choice.** *"approver"* is short and role-shaped — propose it.

**Status.** `draft` — the regional-coverage question is unresolved.

**File:** `docs/notes/pn002.md`

```markdown
---
aliases:
  - approver
status: draft
created: 2026-05-15
---
# Persona [[product]]

## name
Warehouse Approver

## summary
Back-office role that gates sample requests before the warehouse pick list is generated. Reviews submitted requests for budget, inventory, and client-fit signals, then approves or rejects. Decision is the trigger for downstream warehouse work — nothing ships without an approval.

## primary_goals
- Hold the line on inventory not earmarked for paying customers
- Turn submitted requests around fast enough that field reps trust the process
- Surface rejected requests with clear reasoning so the rep can resubmit

## open_questions
- Single approver covering all regions vs regional approvers
- Whether approver and requestor can be the same person for low-value requests
- SLA expectation between submission and decision

---

Index: [[product]]
```

**Confirmation:** *"Wrote `pn002` (approver) at `docs/notes/pn002.md` — stories will reference this as `[[pn002|approver]]`. Status `draft`, 3 open questions. Hub not updated (will surface there when a story references this persona). Anything to revise?"*

## Example 2 — story-write delegates here for a missing persona

**Context.** `infinifu:story-write` is mid-flight on a story whose `role` references *"the brand manager"*. `ls docs/notes/pn*.md` shows `pn001` (requestor) and `pn002` (approver) — no brand-manager persona yet.

**Handoff from story-write:**

> *"No existing persona matches `brand manager`. Delegating to `infinifu:persona-write` to create `pn003`, then I'll resume the story."*

**This skill takes over:**

1. Gathers alias (`brand-manager`), full name (`Brand Manager`), summary, goals, any open questions.
2. Generates id `pn003` (max-of-existing + 1).
3. Writes `docs/notes/pn003.md`.
4. Returns to the caller: `pn003` + canonical alias `brand-manager`.

**Story-write resumes** with `[[pn003|brand-manager]]` in the story's `## role` section, and updates `docs/product.md` to add a new `### [[pn003|brand-manager]]` H3 under `## Stories` plus the bullet for the story it was writing.

**Important:** this skill does **not** touch `docs/product.md`. The hub update is story-write's responsibility because personas surface in the hub only via stories. If persona-write was invoked directly (no story in flight), the hub stays untouched until a story is filed.

## Example 3 — revising an existing persona

**Input:**

> *"Update the requestor persona — we figured out the offline question, they need full offline capture and sync-on-reconnect."*

**Existing persona:** `docs/notes/pn001.md`, status `draft`, `## open_questions` lists *"Offline behaviour expectations when network drops mid-visit"*.

**Action.** Re-emit `pn001.md` with same id, same `aliases[0]`. Remove the offline question from `## open_questions`. The resolution itself goes either:

- As a new bullet under `## primary_goals` if it shapes role intent (*"Capture activity offline; sync on reconnect"*), or
- As a separate ADR if the decision is architectural and constraint-bearing (offline-first sync is an architecture call), then mention the `[[adr####]]` from the persona body.

**Status flip.** If the offline question was the last open question, flip `status: draft` → `status: validated`. If others remain, stay `draft`. The status follows `## open_questions` mechanically — empty list ⇒ `validated`, non-empty ⇒ `draft`.

**Result:**

```markdown
---
aliases:
  - requestor
status: validated
created: 2026-05-15
---
# Persona [[product]]

## name
Field Sales Rep

## summary
Account-facing sales rep who visits client sites and runs tastings. Spends most of the working day off-network; uses the system from a tablet between client visits to log activity and prepare product for upcoming meetings. Low tolerance for multi-step UI — every extra tap is a tap in a parking lot.

## primary_goals
- Get sample product in client hands before each scheduled tasting
- Capture client feedback during the visit, not after
- Hand off promising leads to the office without manual re-keying
- Capture activity offline; sync on reconnect (see [[adr0007]])

## open_questions

---

Index: [[product]]
```

**Note.** `## open_questions` is left as an empty section heading, not deleted — downstream parsers look for the heading. Confirmation message highlights the status flip: *"Re-emitted `pn001` (requestor); status `draft` → `validated`, 0 open questions remaining."*
