Using story-find skill to surface stories touching this area + their validation state.

**Query:** "Which stories cover the catalog area?"
**Tokens:** `["catalog"]` (stripped meta/intent words: which, stories, cover, the, area)

Note: This workspace stores stories as per-file Markdown notes (`docs/notes/us*.md`) with YAML frontmatter and wiki-link tags on the `# Story` heading, not as a single `product/stories.yaml`. The skill's logic is applied against that equivalent structure — `[[tag]]` wiki-links treated as the `tags` field.

---

### us001 — order samples for upcoming client work   (match score: 7)

**As a** requestor (pn001), **I want** to order samples for upcoming client work, **because** I need product in hand for client tasting / presentation.

**Tags:** requestor-flow, catalog, product   **Status:** done

**Acceptance criteria:**
- [x] browse catalog of available samples
- [x] add items with quantity to a request
- [x] submit request to approver

Validated: 3/3 criteria met (status=done).

---

**Coverage for "catalog area":** 1 matched story — 1 done, 0 ready, 0 draft. Top match: us001 (score 7).

Only `us001` carries the `[[catalog]]` tag. The catalog area in this product is currently scoped to "browse catalog of available samples" inside the order-samples flow, and it is marked done. No separate stories describe catalog management, curation, or admin (e.g., adding/removing samples from the catalog) — if that surface needs coverage it is a backlog gap, not an unverified story.
