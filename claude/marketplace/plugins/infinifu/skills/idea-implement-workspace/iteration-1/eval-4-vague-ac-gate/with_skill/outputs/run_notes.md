# Run notes — eval-4-vague-ac-gate (with_skill)

## Task
Apply `infinifu:idea-implement` to `us004` (`status: draft`) in the
seeded Acme sandbox. The story's acceptance criteria are
deliberately vague (`it works`, `fast enough`). The skill's AC-check
step must hold the gate.

## Skill behavior

**Skill loaded:** `infinifu:idea-implement` + shared basics from
`infinifu:idea-brainstorming`.

**Announcement (per the skill):** "Using idea-implement skill to
promote an existing draft story."

**Checklist progression:**

1. **Identify target story** — `us004` named by the user. ✓
2. **Verify status** — `status: draft` in frontmatter. ✓ (proceed)
3. **Read the story** — `## role`, `## want`, `## because` all
   populated. ✓
4. **Persona check** — `## role` resolves to `[[pn001|analyst]]`;
   `pn001.md` exists with `status: validated`. ✓
5. **AC check — GATE HELD HERE.**
   - Body lists only `- it works` and `- fast enough`.
   - Neither is testable (no observable behavior, no numeric
     threshold).
   - Per the skill: "Do NOT promote `status: ready` with untestable
     AC; doing so blocks the whole downstream chain."
   - Per `idea-brainstorming`'s hard-gate clause: "Do NOT invoke any
     implementation skill, write any code, scaffold any project,
     create bd issues, or take any implementation action until you
     have presented a design and the user has approved it."
   - Action: write `gate_reached.md`. Do not proceed to checklist
     items 6-11.

**Steps NOT executed (and why):**

| Step | What it would have done | Why skipped |
|---|---|---|
| 6 Categorize | Pick `[[cat###]]` buckets | AC unresolved — can't pick categories without knowing if search is structured filter, FTS-on-metadata, or FTS-on-bodies. Each shapes a different `cat` set. |
| 7 Survey ADRs | Surface binding decisions | Surveyed for *grounding the gate questions*, not for spec writing. `[[adr0002]]` (90-day retention) is queued as a corpus-scope clarifier. |
| 8 Survey features | List `[[ft###]]` candidates | Surveyed for grounding only. `[[ft001]]` (basic-auth) flagged as inevitable; no new `[[ft###]]` exists for search/indexing and the skill is explicit that we'd mint one at spec-writing — not here. |
| 9 Promote `us###` `draft → ready` | Flip status via `story-write` | Cannot promote with vague AC. |
| 10 Mint `sp###` | Create `docs/notes/spec/sp###.md` | Skill says "every relevant surveyed id must appear in `## problem` as a wikilink" — but the wikilink set depends on the AC clarification, so minting now would either invent ids or omit relevant ones. Both fail the lifecycle contract. |
| 11 Update `docs/board.md` | Append under `## idea` | No spec to link. |

## Files

- **New:** `gate_reached.md` (workspace root, single deliverable for
  this eval). Captures the gate decision and the queued clarifying
  questions, grounded in real zettel ids surfaced by reading the
  AKM context (us001, us002, im001, pn001, cat002, cat003, cat004,
  ft001, adr0002).
- **Modified:** none. `us004.md` is left untouched in `status:
  draft` because the gate held. `docs/board.md` untouched (no spec
  to list). No `sp###` created.
- **Also tracked by `git add -A`:** `.seed_manifest.txt` — a
  pre-existing seed-manifest file that was untracked in the
  sandbox; not produced by the skill, just promoted to staged by
  the blanket `git add -A` in the eval script.

## AC assessment (the substance)

`us004` current AC fail every testability check:

- **"it works"** — observable behavior unspecified. Works in what
  way? What does the analyst type? What do they see? What
  distinguishes a hit from a miss?
- **"fast enough"** — no numeric threshold, no corpus size, no
  percentile, no SLO. Spec-refinement's SRE pass has nothing to
  assert.

The clarifying questions in `gate_reached.md` are ordered by the
shared-basics one-question-at-a-time rule. Q1 is the gate question:
"What does *search* mean?" with three multiple-choice options
(structured filter / FTS on metadata / FTS on bodies) plus
context on why each shapes the downstream `cat` / `ft` / `adr`
picks differently.

Subsequent questions Q2-Q5 cover corpus scope (and the
`[[adr0002]]` 90-day retention inheritance), the "fast enough"
numeric threshold, the trigger surface (extend `[[im001]]` vs new
`[[im###]]`), and the YAGNI out-of-scope list — but in a real
session only Q1 would be sent first, with Q2-Q5 queued.

## Gate decision

**HELD.** No promotion. No `sp###`. No board update.
The chain resumes once the user answers Q1-Q3 with testable
criteria.
