# Run notes — eval-2 (done-story-reject) with_skill

## Decision: REJECT idea-implement, re-route to idea-extend

## Trace

1. Loaded `infinifu:idea-implement` SKILL.md. Confirmed entry contract: skill consumes a `us###` already at `status: draft` and promotes it to `ready` + mints `sp###`.
2. Read sandbox AKM schema (`docs/notes/akm.md`), product hub (`docs/product.md`), board (`docs/board.md`).
3. Walked entry-specific checklist step 1 (identify target story): `us001` named by user; file `docs/notes/us001.md` exists.
4. Walked step 2 (verify status): `us001.md` frontmatter shows `status: done`.
5. Disambiguation hit: `us### exists at status: done → route to infinifu:idea-extend against that story`. Halted the checklist.
6. Cross-checked: `[[im001]]` linked from `us001` is `status: accepted`, confirming the story actually shipped (not just a misclassified label). Board hub is empty (`## idea` / `## spec` / `## ready` all empty), so no in-flight spec contradicts the `done` state.
7. Wrote `<sandbox>/route_decision.md` documenting the reject + the three re-route branches (idea-extend / story-write / story-read).
8. No writes to `us###`, `sp###`, `im###`, `board.md`, or `product.md`. Skill correctly held the gate.

## Files written

- `sandbox/route_decision.md` (NEW) — the route decision artifact.

## Files NOT written (correctly)

- No `sp###.md` minted. Minting a spec for a done story would create a phantom workstream.
- No `us001.md` edit. Flipping `status: done → ready` would be a status regression and corrupt the AKM lifecycle for a shipped story.
- No `board.md` edit. Nothing belongs under `## idea` for this request.
- No `im001.md` edit. The accepted implementation card is append-only; nothing to change pre-extend.

## Skill behaviour assessment

The skill's Disambiguation section made the reject deterministic — one line in the table (`status: done → idea-extend`) carried the whole decision. The status-check at checklist step 2 is the right gate position (before any survey work, before any writes). If the gate had been at step 9 (the actual `story-write` re-emit), the agent would have done wasted survey work first; placing it at step 2 keeps the reject cheap.

One latent risk: a coder ignoring the Disambiguation table and pushing through "we already loaded the story, just flip the bit" would silently regress `done → ready`. The skill mitigates this with the explicit `Key Principles` line "Story exists first, then idea-implement" and the `## acceptance_criteria` discipline. For this eval, the gate held.
