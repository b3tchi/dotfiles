# Summary

## What I wrote

- `docs/notes/deadlock.md` — a new atomic zettel capturing the deadlock concept.

## Why

The user asked to "write down" a definition of deadlock and connect it to two existing notes. I mirrored the shape of the existing cards (`circuit-breaker.md`, `on-call-rotation.md`):

- Same frontmatter keys: `aliases`, `created` (set to today, 2026-05-15).
- Same H1 pattern with the `[[product]]` index wikilink.
- A short, single-sentence definition as the body — keeping the note atomic, matching the terseness of the neighbours.
- A `## see also` section with wikilinks to `[[circuit-breaker]]` and `[[on-call-rotation]]`, as the user explicitly asked.
- Trailing `Index: [[product]]` footer to match the vault convention.

I added a brief `## context` line noting the payment-queue incident, since the user mentioned it as the reason for capturing the note — useful provenance without bloating the atomic concept.

I did not modify the existing notes (read-only per instructions), so the back-links from `circuit-breaker` / `on-call-rotation` to `deadlock` are not added; that would be a follow-up edit if the user wants reciprocal links.
