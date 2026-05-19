# Summary — eval-3 (route-to-story-write)

**Routing decision.** `zettel-write` -> `story-write`. The request was Connextra-shaped (persona "field reps" + want "bulk csv contact upload" + because "don't waste evenings typing entries one at a time"). Single atomic claim, so the atomicity gate passed without a split, and the routing table maps this shape directly to `us###`.

**What was written.** `outputs/us001.md` — a new AKM Story zettel in `draft` status. Schema per `akm.md`: frontmatter (aliases, status, created), H1 `# Story [[product]]`, body sections `## role` -> `[[pn001|field-rep]]`, `## want`, `## because`, `## acceptance_criteria` (4 bullets), `Index: [[product]]` footer. ID `us001` was chosen to align with the pre-seeded `[[us001|bulk csv contact upload]]` wikilink already in `docs/product.md`.

**Why.** Routing was unambiguous. Acceptance criteria were derived (the user gave none) and flagged as such — they cover entry point, preview-before-commit, row-level error handling, and the success path. Tags were intentionally omitted because the existing vault taxonomy (`cat001|infrastructure`, `cat002|reliability`) does not fit a CSV-upload product story, and inventing dangling tags would be noise. Status is `draft` because criteria are model-derived rather than user-confirmed.

See `decision-log.md` for the per-decision rationale.
