# Run notes — spec-refinement on sp001 (eval-2-adr-conflict)

## Decision

**BLOCKED.** Wrote `sandbox/route_decision.md` asking the user to
resolve two upstream gaps before refinement can run. Spec file
`docs/notes/spec/sp001.md` left unchanged; no `## plan`, no `## tasks`,
no `## specs` back-link written.

Took the "block + route_decision" branch (not the "include supersession
task in breakdown" branch). Rationale below.

## Conflicts detected by the sanity passes

### 1. ADR sanity — adr0001 contradiction (silent supersession)

- `sp001.## solution` proposes mutual-TLS replacing ft001 basic-auth for
  service-to-service traffic and states "[[adr0001]] is *implicitly*
  superseded by this approach."
- `adr0001` is `status: Accepted`, under `[[cat001]]` security (one of
  sp001's H1 categories). Its `## decision`: "Every service uses ft001
  (password+TOTP)."
- Per SKILL.md `## ADR / Feature sanity`: silent ADR violation =
  ship-blocker. The word "implicitly" is exactly the anti-pattern the
  rule names.
- Resolution per skill: either (a) add a Task "File new ADR superseding
  [[adr0001]]" *before* any dependent task, or (b) block and route.

### 2. Disambiguation — `## implements [[im002]]` does not exist

- `sp001.## implements` points at `[[im002|vault-policy credential
  rotation for live services]]`.
- `docs/notes/im002.md` is not on disk. Only `im001` exists.
- SKILL.md Disambiguation explicitly says: *"No `[[im###]]` referenced
  in `## solution`** → block."* Same rule applies when the referenced
  zettel doesn't exist — the back-link the skill is responsible for
  finalizing (`## specs` on the consumed im###) has no target.

### 3. Internal inconsistency between alias and body (informational)

- `im002`'s alias text is "vault-policy credential rotation" — a
  *vault-based* approach that would consume `[[ft002|vault-secrets]]`.
- `sp001.## solution` body describes the *opposite* approach (mTLS, ft002
  "not used at all").
- Suggests upstream churn: either `## implements` was not updated when
  `## solution` flipped to mTLS, or the body is stale. Either way the
  fix is upstream of spec-refinement (spec-writing or idea-implement).

## Why "block" rather than "add supersession task in breakdown"

The skill offers both routes for the ADR conflict alone. Two reasons to
block:

1. **Compounding issue 2 is a hard block.** Even if I drafted the
   breakdown with a supersession task as task 1, the deliverable
   "finalize `## specs` back-link on the consumed `[[im###]]`" cannot be
   completed — `im002` doesn't exist. The skill explicitly lists this in
   Disambiguation as block-grade.
2. **Scope of the architecture change is bigger than refinement.**
   Bypassing a `stable` feature with multiple consumers (ft001), and
   introducing a new internal CA + cert lifecycle, is a design-level
   change. The skill's job is to turn an *agreed* solution into an
   executable plan; here the solution itself needs re-litigation
   upstream (idea-* or spec-writing). Polishing tasks on a foundation
   that may flip back to vault-policy is wasted work.

## What the user must pick

`route_decision.md` lays out three concrete routes:

- **A** — Keep mTLS, file `adr0004` superseding `adr0001`, decide ft001
  fate (deprecate vs supersede), mint real `im002`, update sp001, then
  re-run refinement.
- **B** — Honor `adr0001`, rewrite `sp001.## solution` to the
  vault-policy approach the alias hints at, mint `im002` for it, re-run
  refinement.
- **C** — Drop `sp001` (flip status, remove from board), leave us003 for
  a future iteration.

## SRE 8-category pass — skipped (intentional)

No task breakdown was drafted, so the 8-category pass had nothing to
grade. Running SRE on a list built atop a silent ADR violation would
just polish a ship-blocker. Skill discipline: foundation first, SRE
after.

## Files written / modified (final state)

- **New (sandbox):** `route_decision.md` (root of sandbox, not under
  `docs/notes/` — it is an ephemeral routing artifact, not a zettel).
- **Modified:** none.
- **Not touched:** `docs/notes/spec/sp001.md`, `docs/notes/im*.md`,
  `docs/board.md`, `docs/notes/adr0001.md`. Untouched is the correct
  outcome on block.

## Skill behavior — strengths surfaced by this case

- The "ADR / Feature sanity (after SRE pass)" section gave a clean rule
  to point at: "silent violation = ship-blocker". Made the call
  obvious.
- The Disambiguation matrix listed the missing-im### case explicitly,
  preventing me from forging ahead.
- The "out of scope" note (no bd, no status promotion, no board edits)
  kept the block surgical — I didn't touch board.md to "park" the spec.

## Skill behavior — friction surfaced

- The skill announces ADR sanity *after* the SRE pass. In this case the
  ADR problem was visible from `## solution` before any task was
  drafted; running SRE first would have been wasted work. A short
  "pre-SRE foundation check (im### exists, no `implicitly superseded`
  language in `## solution`)" would catch ship-blockers earlier and
  avoid the temptation to grade a doomed breakdown.
- The skill says "Surface as design-approval gate to the user — the
  breakdown is a commitment". When blocking, the equivalent gate isn't
  named. `route_decision.md` is my interpretation; the skill could
  benefit from naming "on block, write a route_decision artifact" as
  the canonical output shape.
