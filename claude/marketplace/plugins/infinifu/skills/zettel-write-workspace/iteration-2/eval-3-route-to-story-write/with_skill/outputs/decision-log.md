# Decision Log — eval-3 (route to story-write)

## Atomicity gate
Single claim restated: "Field reps want to bulk-upload contacts via CSV so they don't spend evenings retyping entries from the day's fieldwork." No "and"/"also"/hidden compound. PASS.

## Type detection
Request shape: Connextra-style backlog item — persona (field reps), want (bulk csv contact upload), because (avoid evening re-typing). Matches `us###` row in routing table. Route → `infinifu:story-write`.

## ID generation
`ls docs/notes/us*.md` → no existing story files. Next id = `us001`. Matches the pre-seeded `[[us001|bulk csv contact upload]]` reference in `product.md` — the hub anticipated this id.

## Persona
Hub pre-seeds `[[pn001|field-rep]]` under `## Stories`. Used `[[pn001|field-rep]]` in `## role`. Note: `pn001.md` does not yet exist in the vault, so the link will dangle until the persona zettel is written. Acceptable per AKM (moxide diagnostics will flag, but the hub already establishes the convention).

## H1 tags
No flow/area/theme zettels exist in the vault (only `circuit-breaker`, `on-call-rotation`, `akm`, plus the categories `cat001`/`cat002` which are not story-relevant). Per skill rule "never fabricate a tag wikilink just because the type's schema allows it", H1 carries only `[[product]]`.

## Status
`draft` — new capture, acceptance criteria derived (not user-supplied).

## Acceptance criteria
User supplied zero criteria. Non-interactive mode (instructions say "decide without asking"). Derived 4 baseline criteria from want+because covering: entry point (csv upload from contacts screen), validation (preview + row-level errors), partial-failure handling (commit valid, reject bad without aborting), parity (imported rows look like manual ones). Flagged as derived in summary.md.

## Priority
User said "medium-ish, not urgent." AKM story schema has no `priority` field. Noted here only; not persisted in the zettel. If priority tracking is needed later, that's a bd-board concern (epic/task), not a story-zettel concern.

## Hub update
`docs/product.md` is read-only per task instructions (vault state). The hub already lists `[[us001|bulk csv contact upload]]` so no update is required — the pre-seeded entry now resolves.

## Post-write audit
- Single idea: yes (one Connextra sentence: "As a field-rep, I want to upload a csv of contacts in bulk instead of entering them one by one, because field reps lose evenings re-typing entries at the office that they already collected during the day.")
- Body length: ~10 lines body, well under 30.
- Outbound wikilinks beyond `[[product]]`: yes — `[[pn001|field-rep]]` in `## role`.
- AKM invariants: `[[product]]` in H1 ✓, `Index: [[product]]` footer ✓, filename `us001.md` ✓.
- Schema: matches `akm.md` Story schema exactly (aliases/status/created frontmatter; role/want/because/acceptance_criteria sections).

PASS.
