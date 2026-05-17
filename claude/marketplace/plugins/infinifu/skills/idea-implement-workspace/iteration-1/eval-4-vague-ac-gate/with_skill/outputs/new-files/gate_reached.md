# Gate reached — `us004` AC are not testable

**Skill:** `infinifu:idea-implement`
**Target:** `[[us004|search reports somehow]]` (status: `draft`)
**Persona:** `[[pn001|analyst]]` (validated — OK)
**Outcome:** Gate held. No promotion to `status: ready`. No `sp###` minted.
No board update. No design proposed yet.

## Why the gate held

The skill's AC-check step (checklist item 5) says:

> If `## acceptance_criteria` is empty or vague, this is the
> design-approval question — ask the user for testable criteria.
> Do NOT promote `status: ready` with untestable AC; doing so blocks
> the whole downstream chain.

Current `us004` acceptance criteria:

- `it works`
- `fast enough`

Neither is verifiable. "It works" has no observable behavior bound
to it; "fast enough" has no numeric threshold, no payload size, no
percentile. Spec-writing would have no plan target; spec-refinement
would have no SRE-pass anchor; `work-audit` would have no pass/fail
condition. The chain is blocked at the source — refining AC is the
prerequisite, not a downstream concern.

## Surveyed AKM context (grounding for the questions)

So the clarifying questions below are anchored in real zettel ids,
not invented:

- **Story area:** H1 carries `[[reports-flow]]` (a tag; no backing
  zettel — that's fine per AKM, dangling tags allowed).
- **Persona:** `[[pn001|analyst]]` — Operations Analyst, lives in
  the reports service UI. Primary goal: "pull report results without
  engineering help".
- **Related shipped story:** `[[us001|view dashboard of recent
  reports]]` (`status: done`) — already lists the last 20 reports
  per analyst with status + CSV links via
  `[[im001|reports dashboard via reports-service UI]]`. Search
  almost certainly extends this surface.
- **Related ready story:** `[[us002|filter reports by date range]]`
  (`status: ready`) — already covers date-range filtering
  *client-side over the last 20 rows*. Overlap risk: a date filter
  in `us004` would duplicate `us002` unless we scope it as
  server-side over the full retention window.
- **Candidate categories the story touches:**
  - `[[cat002|data]]` — query patterns over `report_runs`.
  - `[[cat003|infrastructure]]` — if search needs an index
    (Postgres FTS, separate engine, etc.).
  - `[[cat004|observability]]` — if "fast enough" implies an SLO we
    have to measure.
- **Binding ADR:**
  - `[[adr0002|Reports written to Postgres, retained 90 days]]` —
    constrains the corpus to the trailing 90 days. Anything older is
    "off-platform" by decision. The user must know whether `us004`
    inherits that 90-day window or requires reopening the ADR.
- **Candidate feature consumers:**
  - `[[ft001|basic-auth (password+TOTP)]]` — search endpoint will
    need `require_auth` like every other reports route.
  - No existing `ft###` covers search/indexing; if we go that route
    we'd mint one at spec-writing, not here.
- **Existing implementation to extend:**
  - `[[im001|reports dashboard via reports-service UI]]` —
    `src/services/reports/dashboard.py` + templates. The search UI
    likely lands next to this; whether `im001` is extended or a new
    `im###` is created is a spec-writing decision, not an
    idea-implement one.

## Clarifying questions (one-question-at-a-time cadence)

Per `idea-brainstorming` shared basics, only **Q1** would actually
be sent to the user in the live session; Q2-Q5 are queued and surface
after each prior answer. Listed together here only because the eval
asks for the gate contents in one shot.

### Q1 — What does "search" mean? (the gate question)

The word `search` covers very different shapes. Pick one (or describe
something else):

- **A. Filter by structured fields.** Analyst picks report name,
  status, date range, owner from dropdowns/inputs over the existing
  `report_runs` rows. No free-text. (Closest in cost to `us001` /
  `us002`. Risk: overlaps with `[[us002]]`'s date-range filter
  unless we scope this as "structured filter beyond date".)

- **B. Full-text search over report metadata.** Analyst types a
  phrase; we match against report `name`, `description`, owner,
  triggering-job id, tags. Postgres `tsvector` is enough at our
  corpus size; no separate engine.

- **C. Full-text search over report *contents* (the CSV bodies).**
  Analyst types a phrase that appears inside a row of a generated
  report. Requires indexing the CSVs (cost, infrastructure, retention
  questions all become live — `[[adr0002]]` only covers the
  `report_runs` table, not body contents).

The answer determines the category set
(`[[cat002]]` alone for A/B; `[[cat002]] [[cat003]]` for C),
whether `[[adr0002]]` is sufficient or needs revisiting, and
whether a new `[[ft###]]` (search/index capability) is on the table.

### Q2 — What corpus does search cover?

After Q1 is answered:

- **A.** Only the trailing 90 days (inherits `[[adr0002]]`
  retention).
- **B.** Trailing 90 days *plus* off-platform exports (means
  reopening the ADR or scoping search to the warehouse, not the
  service).
- **C.** Only the analyst's own reports (matches `[[pn001]]`'s
  current scope in `[[us001]]`).
- **D.** All analysts' reports they have read access to
  (introduces an authorization layer — possibly a new `[[ft###]]`).

### Q3 — What does "fast enough" mean numerically?

A testable AC needs a threshold. Pick the shape:

- **A.** p95 query latency under N ms for a corpus of M rows
  (need both N and M).
- **B.** p95 latency under N ms *and* index build under K minutes
  during the nightly retention job.
- **C.** No latency target — "interactive feel only", which we'd
  then reword as "renders without spinner > 1s on standard analyst
  result counts" so it's still observable.

Without a number here, `[[cat004|observability]]` doesn't get a
hook and spec-refinement's SRE pass has nothing to assert.

### Q4 — How does the analyst trigger search?

- **A.** New `/search` route in the reports service, separate page.
- **B.** Search box on the existing `[[im001]]` dashboard,
  results inline.
- **C.** API-only first (`GET /search?q=...` returning JSON), UI in
  a follow-up story.

This is the difference between extending `[[im001]]` versus minting
a new `[[im###]]` at spec-writing.

### Q5 — What's *out of scope*? (YAGNI gate)

Explicitly call out non-goals so the AC stays bounded:

- Search across other services (audit log, vault, alerts) — likely
  out.
- Saved searches / search history — likely out for v1.
- Result export (re-running a found report is via `[[us001]]`
  already) — likely out.
- Permissions beyond what `[[ft001]]` already enforces — depends
  on Q2.

## What happens after the user answers

Once Q1-Q3 are resolved with concrete answers (Q4-Q5 can land during
design):

1. Rewrite `## acceptance_criteria` in `us004.md` to be testable
   (e.g., "Analyst can search their last-90-days reports by free
   text matching `report_runs.name` + `report_runs.description`;
   p95 latency < 300ms for a 10k-row corpus; only own reports
   returned").
2. *Then* propose 2-3 design approaches grounded in the surveyed
   ids (`[[cat002]]`, `[[cat003]]` if needed, `[[ft001]]`,
   `[[adr0002]]`, `[[im001]]`).
3. *Then* flip `us004` `status: draft → ready` via `story-write`.
4. *Then* mint `sp###` with `## solves [[us004]]` and `## problem`
   citing every surveyed id as a wikilink.
5. *Then* append `[[sp###|search reports]]` under `## idea` in
   `docs/board.md`.

None of those steps happen in this turn. The gate holds.
