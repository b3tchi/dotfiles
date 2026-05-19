# Run notes — iteration-2, with_skill

**Tasks written:** 10 (`## Task 1` … `## Task 10`).

**Heading levels used:**
- H1: spec title only.
- H2: every sibling section — header prose block (Goal/Architecture/Tech Stack as bold labels, not headings), `Conventions`, `File tree`, each `Task N`, and `Remember`.
- H3: none needed — step markers inside tasks are **bold** (`**Step 1: ...**`), keeping the outline flat and scannable per the new skeleton.

**Completeness of the new template:** Felt essentially complete. The end-to-end example in the Document Skeleton made it obvious that `## Task N:` is H2 and steps are bold, which removed the main ambiguity from iteration-1 (mixing `###`/`####` inside tasks). The optional `Conventions` and `File tree` H2s slotted in cleanly before Task 1.

**Residual ambiguity:**
1. Task 10 is a pure verification task with nothing to write; the rigid 5-step structure didn't fit naturally — I marked Steps 1–3 as N/A. A one-line note in the skeleton permitting "verification-only final task" would help.
2. Task 8 tests code introduced in Task 7, so its "Step 2 fails" is conditional. The skeleton's strict RED→GREEN framing doesn't cover follow-on test-only tasks cleanly.
3. The skeleton doesn't explicitly say where cross-task dependency callouts belong; I put them as a `> Dependency:` blockquote at the top of dependent tasks, which worked but is my invention.

Overall the new single "Document Skeleton" section was clearer than the prior split.
