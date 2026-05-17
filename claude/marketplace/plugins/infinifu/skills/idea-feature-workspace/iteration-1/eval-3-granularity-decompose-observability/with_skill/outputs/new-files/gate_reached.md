# Hard-gate reached — idea-feature for "unified observability stack"

Announce: **Using idea-feature skill to scope a new horizontal capability.**

Stopping at the brainstorming hard gate before minting any `sp###`. The
request bundles several distinct capabilities into "one feature"; that
granularity choice has to be settled before a spec is drafted, because
each split-vs-bundle option produces a materially different `sp###`
problem statement (and ultimately a different number of `ft###` cards
at spec-writing time).

## AKM survey (concrete, grounded)

### Dedup check — `feature-read`

Existing features in `docs/notes/`:

- `ft001` — basic-auth (password+TOTP). Category `cat001`. No overlap.
- `ft002` — vault-secrets. Category `cat001`. No overlap.

No existing feature covers metrics, logs, tracing, alerting, or
dashboards. Greenfield under `cat004` (observability). No re-route to
`idea-extend` is warranted.

### Categories — `category-read`

- `cat004` (observability) — exists, stable, exact fit:
  *"Metrics, logging, tracing, alerting paths."*
- `cat003` (infrastructure) — secondary fit for the cross-service
  plumbing aspects (collectors, exporters, broker if any).

No new category needs minting.

### Binding ADRs under picked categories — `adr-read --category cat004 cat003`

- Under `cat004`: **none**. The space is unconstrained, which itself
  is a constraint to flag — we're free to pick OpenTelemetry vs raw
  Prometheus vs vendor without overturning a prior decision.
- Under `cat003`: `adr0003` (no external SMTP relay; services use
  smtplib directly). Relevant analogue, *not binding*: alerting will
  need an email/notification path; the precedent says "no relay
  service yet". An observability alert path that emails on-call would
  be the first thing to question that precedent (or live with it via
  smtplib reuse).

### Plausible consumers — `story-find` / `story-read`

- `us001` (done, reports-flow) — currently logs to stdout; would
  consume structured logging + dashboards.
- `us002` (ready, reports-flow) — same surface; same consumption.
- `us003` (ready, platform-flow) — *"no 5xx during rotation window
  in synthetic check"* — explicit synthetic-check AC. Needs metrics
  + alerting to verify.

All three services (`auth`, `metrics`, `reports`) are plausible
consumers of each sub-capability. Consumer count is healthy — this is
not the "one consumer = not a feature" anti-pattern; it's the
opposite extreme.

### Ad-hoc implementations to migrate — `implementation-read`

Per `README.md`:

- `src/services/metrics/` — "Prometheus scraper, alerts via stdout
  for now". Migration target for **metrics scraping** and **alerting**.
- `src/services/reports/` — "emails CSV when done", stdout logs.
  Migration target for **structured logging**.
- `src/services/auth/` — stdout logs implied. Migration target for
  **structured logging** + **tracing** (auth is a common trace entry
  point).
- `im001` (reports dashboard) — consumes `ft001` but no obs at all
  today; would gain dashboards + logs.

## Granularity observation (the load-bearing one)

The skill's `## Key Principles` says:

> A feature with one consumer is not a feature. Features are reusable
> by definition.

The dual rule (implicit in `feature-write` and the AKM `Feature`
schema) is **one capability per `ft###`**. The Feature body has a
single `## providing` paragraph and a single `## api_surface` — the
schema literally can't carry five orthogonal capabilities.

"Unified observability stack — metrics scraping, structured logging,
distributed tracing, alerting, and dashboards" packs **five** distinct
horizontal capabilities:

| # | Capability | Consumers | api_surface shape | Owns state? |
|---|---|---|---|---|
| 1 | Metrics scraping/exposition | every service emits counters/histograms | `metric(name).inc()` / scrape endpoint | retention in TSDB |
| 2 | Structured logging | every service writes log records | `log.info(event, **kv)` | log store + retention |
| 3 | Distributed tracing | request-path services (auth, reports) | `trace.span()` context-mgr / middleware | trace backend + sampling |
| 4 | Alerting | metrics + logs (consumes 1 and 2) | rule definitions + notification routes | rule store + dedup state |
| 5 | Dashboards | analysts + on-call | dashboard-as-code definitions | dashboard config store |

Each has its own:

- ADRs it would attract (sampling rate, retention, allowed cardinality,
  alert routing, dashboard governance).
- Consumer surface (1, 2, 3 are emit-side libs; 4 is rules + routes;
  5 is a UI + config layer).
- Migration target (1 replaces `src/services/metrics` ad-hoc scraper;
  2 replaces stdout in all three services; 4 replaces stdout alerts;
  etc.).
- Lifecycle (logging is table-stakes day-1; tracing is usually phase 2;
  dashboards lag content).

Bundling them into one `ft###` would produce a card whose `providing`
is a paragraph of "and… and… and…" and whose `api_surface` couldn't
be coherently described. It would also force a single `status:` flag
across capabilities that ship on different timelines.

## Proposed re-shape (recommended)

Treat the request as **a program**, not a feature. Mint **one
`sp###`** at the *idea* stage describing the program's boundary and
intent, with the explicit plan that spec-writing will fan it out into
**up to five `ft###` cards** (some may consolidate at design time —
e.g. metrics + alerting could pair, or alerting may layer on a
generic notification ft### that we *also* need given `adr0003`'s
smell).

Concretely, the `sp###` `## problem` would frame:

- **Capability boundary:** observability program covering emit-side
  (metrics, logs, traces) and consume-side (alerting, dashboards).
- **Consumers:** all three services (`auth`, `metrics`, `reports`);
  also future services by default.
- **Constraints inherited:** none from `cat004` ADRs (clean slate);
  `adr0003` precedent on "no extra services" to interrogate when we
  hit alerting.
- **Migration intent:** retire stdout logging across `auth`,
  `metrics`, `reports`; retire ad-hoc Prometheus calls in
  `src/services/metrics/`; retire stdout alerts.
- **Decomposition intent (spec-writing input):** five candidate
  `ft###` slots — `ft-metrics`, `ft-logging`, `ft-tracing`,
  `ft-alerting`, `ft-dashboards` — with explicit notes on which can
  consolidate and which must stand alone.

This is consistent with the skill's `## AKM hooks` write set: at idea
stage we only emit `sp###` + a board entry, *no* `ft###` is minted
yet, "to avoid a half-formed feature ending up in the registry". The
program-shaped problem is exactly the kind of half-formed shape the
deferred `ft###` rule exists for.

## Alternative options I'd present to the user (2-3 design approaches)

**Option A (recommended): one `sp###` framed as a multi-feature
program.** Spec-writing fans out into `ft-logging` first (highest
consumer count, lowest risk), then `ft-metrics` + `ft-alerting`
paired, then `ft-tracing`, then `ft-dashboards`. Migration is staged.

**Option B: five separate `sp###` cards in `## idea` right now.** One
per capability. Each is small and shippable. Cost: loses the "shared
collector / shared agent / shared SDK" framing — they end up
designed-in-isolation and we pay the integration cost later.

**Option C: one `sp###` for the *foundation* (collector + structured
logging + metrics SDK as one ft### — the emit-side platform), with
tracing / alerting / dashboards filed as separate follow-up `sp###`
cards.** Treats "observability platform" as ft### #1 and the
specialized capabilities as later ft### cards layered on top. Middle
ground.

## What I would ask next (one MC question)

> The observability ask bundles 5 capabilities (metrics, logs,
> tracing, alerting, dashboards). At the AKM Feature granularity,
> that's multiple `ft###` cards, not one. How should we frame the
> `sp###`?
>
> 1. **Program-shaped sp### (recommended)** — one `sp###` whose
>    problem describes the full program; spec-writing splits it into
>    up to 5 ft### with explicit consolidation decisions.
> 2. **Five sp###** — one per capability under `## idea` on the
>    board, designed independently.
> 3. **Foundation-first sp###** — one ft### bundling
>    emit-side (logs+metrics+SDK), separate sp### later for tracing /
>    alerting / dashboards.

## Why I'm not minting `sp###` yet

The hard gate: *"Do NOT … take any implementation action until you
have presented a design and the user has approved it."* The
split-vs-bundle call is a load-bearing design decision; minting an
`sp###` for "one feature: observability" would encode the bundled
framing and force spec-writing to either accept the malformed shape
or rewrite the `## problem` (rewriting `sp###.problem` after the
fact is an explicit anti-pattern of the skill — it's why the
`docs/board.md` entry points at the sp file).

## Deviations from the skill checklist

None. I executed steps 1-5 (dedup, consumers, ad-hoc inventory,
categorize, ADR survey) and stopped before step 6 (migration sketch
finalization) and step 7 (mint `sp###`) because the granularity
question changes what the `## problem` body says. The skill's hard
gate is what justifies stopping here, not a refusal to commit.
