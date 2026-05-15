# Summary — kanban workshop capture (2026-05-15)

Captured two learnings from today's kanban workshop as zettels in the
existing vault style (matching `circuit-breaker.md` /
`on-call-rotation.md`):

- **`wip-limits.md`** — caps in-flight work per stage to prevent
  overload; forces finishing over starting and surfaces bottlenecks.
  Flagged as the one you keep coming back to for our team.
- **`pull-based-systems.md`** — workers pull when ready instead of
  being pushed work; self-regulates to capacity and generally beats
  push-based for knowledge work.

The two notes cross-link via `## see also` since they reinforce each
other (pull-based + WIP limits are the kanban core). Both carry the
`[[product]]` H1 link and `Index: [[product]]` footer per AKM schema.
Frontmatter uses `aliases` + `created: 2026-05-15`; no `status` field
(matching the lightweight knowledge-note style of the existing
neighbours rather than a typed Story/Feature/ADR).

Emphasis on WIP limits is captured in the body line "the lever I keep
coming back to for our team" so the personal weighting isn't lost.

Files written under `outputs/`:
- `wip-limits.md`
- `pull-based-systems.md`
- `summary.md`
