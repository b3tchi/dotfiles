# Decision log — eval-2 compound-split prompt

## Input

User asked to capture two learnings from a kanban workshop:
1. WIP limits prevent overload by capping in-flight work.
2. Pull-based systems beat push-based because they self-regulate.

The user added a preference signal: "the WIP limit one is the one I keep coming back to."

## Atomicity gate

The request contains "and" plus two distinct subjects (WIP limits / pull-based systems) with two distinct verbs (cap in-flight work / self-regulate to capacity). It cannot be restated as a single declarative sentence without losing one claim. **Verdict: compound — must split.**

Output rule #2 says decide without asking. Decision: write both as separate atomic cards with mutual `[[…]]` links. Rationale:

- Both ideas have independent re-use value (WIP limits show up outside pull systems — e.g. as a guardrail on push pipelines; pull-based flow is a broader pattern than just kanban WIP caps).
- The user's preference for the WIP-limit idea is a *salience* signal, not a *scope* signal — collapsing the pull-flow card would lose a legitimate atomic concept that may anchor future cards (queue theory, Little's Law, Toyota production system, etc.).
- Mutual `## see also` linking preserves the "they go together" intuition the user expressed, without breaking atomicity.

## Type detection

Neither claim matches a typed AKM bucket:

- Not a Story (no persona / want / because shape, no Connextra phrasing).
- Not an ADR (no "we chose X over Y for this product" decision — these are general concepts learned at a workshop, not commitments for this codebase).
- Not a Feature / Implementation / Persona / Category.

**Route: generic named-slug cards** at `docs/notes/<slug>.md` per skill Step 3.

## Slug choices

- `wip-limits.md` — reads as `[[wip-limits]]`. Considered `[[work-in-progress-limits]]` (too long) and `[[wip-cap]]` (less standard vocabulary).
- `pull-based-flow.md` — reads as `[[pull-based-flow]]`. Considered `[[pull-systems]]` (ambiguous with electrical/UI pull patterns) and `[[kanban-pull]]` (over-narrows; the concept is broader than kanban).

## Outbound link choices

Existing vault zettels available: `circuit-breaker`, `on-call-rotation`, plus the typed singletons (`product`, `akm`).

- `wip-limits` → `[[pull-based-flow]]` (the sibling card; conceptual pair) + `[[on-call-rotation]]` (WIP caps and on-call load both speak to operator overload).
- `pull-based-flow` → `[[wip-limits]]` (mutual; sibling card) + `[[circuit-breaker]]` (both are downstream-protection mechanisms — circuit breaker as the runtime analogue of refusing to pull).

Each card therefore satisfies the ≥ 1 outbound link rule with two real links beyond `[[product]]` / `Index:`.

## Post-write audit

| Check | wip-limits | pull-based-flow |
|---|---|---|
| Single-sentence restatement, no compound | pass | pass |
| Body ≤ 300 words / ~30 lines | pass (~85 words) | pass (~80 words) |
| ≥ 1 outbound wikilink beyond `[[product]]`/`Index:` | pass (2) | pass (2) |
| `[[product]]` in H1 + `Index: [[product]]` footer | pass | pass |
| Filename = stable kebab slug, no date/owner | pass | pass |
| Generic schema (aliases + created, no status, `## see also`) | pass | pass |

Both files pass — no rejection/rewrite cycle needed.
