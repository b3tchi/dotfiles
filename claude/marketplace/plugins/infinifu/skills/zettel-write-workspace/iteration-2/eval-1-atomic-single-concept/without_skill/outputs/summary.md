# Summary

Captured a single-concept zettel note for "deadlock" based on the user's spoken-style request.

## Artifact
- `deadlock.md` — atomic note containing the definition (two threads each holding a resource the other needs), the incident context (payment queue, last week), and wiki-style links to the two referenced notes.

## Decisions
- **Filename**: `deadlock.md` — matches the existing kebab-case slug convention (`circuit-breaker.md`, `on-call-rotation.md`).
- **Frontmatter**: mirrored the existing notes' shape — `aliases` (one descriptive line) and `created` (today, 2026-05-15).
- **H1**: `Deadlock [[product]]` — follows the pattern of linking back to the product index from the heading.
- **Body**: kept it atomic — the core definition as the lead sentence, then a single line of incident context. No prose bloat.
- **Links**: added `[[circuit-breaker]]` and `[[on-call-rotation]]` under a `## see also` section as the existing notes do. Did not edit those notes to back-link, since the vault is marked read-only.
- **Footer**: `Index: [[product]]` to match house style.

## Not done
- Reciprocal back-links from `circuit-breaker.md` / `on-call-rotation.md` to `deadlock.md` — vault is read-only per instructions.
