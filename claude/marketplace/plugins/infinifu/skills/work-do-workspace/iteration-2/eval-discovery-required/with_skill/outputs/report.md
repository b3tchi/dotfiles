# work-do report: eval-rtd

Status: blocked (ready for review by dispatcher / work-audit).

## Task
- Original task: eval-rtd — "Implement title_slug_with_date"
- Intent: add title_slug_with_date(title, date) -> str to src/slugs.py, delegating date formatting to src/dates.py::format_iso.

## What I did
1. Read the task via `bd show eval-rtd` and the work-do SKILL.md end-to-end.
2. Claimed the task: `bd update eval-rtd --status in_progress`.
3. Verified src/dates.py does not exist in the sandbox (only src/__init__.py and src/slugs.py are present).
4. Per the task's explicit Out-of-scope directive, did NOT create src/dates.py.
5. Filed a discovery task:
   - Discovery task ID: eval-2t0 — "Discovered: implement src/dates.py format_iso"
   - Design covers: export format_iso(date) -> str returning YYYY-MM-DD; tests in tests/test_dates.py for standard date, zero-padded month/day, leap day; out-of-scope for ISO parsing and timezones; notes that it unblocks eval-rtd.
6. Linked the discovery: `bd dep add eval-2t0 eval-rtd --type discovered-from`. Verified via `bd dep tree eval-2t0`:
     eval-2t0: Discovered: implement src/dates.py format_iso [P2] (open) [READY]
         └── eval-rtd: Implement title_slug_with_date [P2] (blocked)
7. Recorded a comment on the original task pointing at the discovery:
   "DISCOVERY: filed eval-2t0 for missing src/dates.py. Per this task Out-of-scope, not implementing src/dates.py here."
8. Moved the original task to blocked with a BLOCKED note pointing at eval-2t0.

## Why I stopped
The eval-rtd task body says verbatim: "Do NOT implement src/dates.py if it is missing. File a discovery task via bd create ... and link it with bd dep add <new-id> <this-task-id> --type discovered-from." Implementing title_slug_with_date without src/dates.py would either silently expand scope by adding the missing module — forbidden by the task — or stub around the dependency, diverging from spec. Per work-do Step 5 (Handle discoveries) and the Silent scope expansion anti-pattern, the correct action is to file the discovery, link it, and block the current task until the discovery is resolved. No source files were touched; no tests were added.

## Final state
- eval-rtd: blocked, NOT closed. Notes reference the discovery. Comment logged.
- eval-2t0: open, ready. Linked to eval-rtd via discovered-from.
- src/dates.py: does not exist (sandbox unchanged).
- No code, no tests added.

## Next steps (for the dispatcher / reviewer)
1. Schedule eval-2t0 (it is ready).
2. Once eval-2t0 is implemented and reviewed, move eval-rtd back to open/ready so an implementer can complete title_slug_with_date.
