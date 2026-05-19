# Summary

Compound request (kanban-workshop learnings) split into two atomic generic concept cards with mutual links. Decision made without asking per output rule #2; rationale in `decision-log.md`.

## Cards written

**`wip-limits.md`**
- Claim: A WIP limit caps in-flight work, forcing finishing over starting and exposing bottlenecks the moment the cap is hit.
- Outbound links (beyond `[[product]]`/`Index:`): `[[pull-based-flow]]`, `[[on-call-rotation]]`.

**`pull-based-flow.md`**
- Claim: Pull systems self-regulate because downstream signals capacity and upstream cannot release without it; push hides queues and trades latency for local throughput.
- Outbound links: `[[wip-limits]]`, `[[circuit-breaker]]`.

## Skill checks run

Atomicity gate: detected compound (two subjects, two verbs, "and") → split into two drafts. Type detection: neither claim matches `us`/`pn`/`ft`/`im`/`adr`/`cat` → routed both to generic named-slug card per Step 3. Post-write audit (Step 4): both pass single-idea restatement, body ≤ 300 words (~80–85 each), ≥ 1 outbound wikilink beyond `[[product]]`/`Index:` (each has 2), AKM invariants (`[[product]]` in H1, `Index:` footer), and generic schema (aliases + created, no status, `## see also`). User's "I keep coming back to WIP limits" read as salience, not scope reduction — both cards stay independently reusable.
