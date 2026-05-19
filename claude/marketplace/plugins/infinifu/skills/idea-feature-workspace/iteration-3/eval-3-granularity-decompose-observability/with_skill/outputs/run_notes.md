# Run notes — idea-feature observability evaluation (iteration 3)

## Outcome
Emitted 5 sp### zettels in `docs/notes/spec/` and updated `docs/board.md`. No hard gate reached — the skill's checklist applied cleanly. No `ft###` minted (per the skill: minting happens at spec-writing time, not idea stage).

## ft### candidate count
**5 atomic ft### candidates** — one per capability the user packed into "observability stack":
1. metrics-scraping (scoped in [[sp001]])
2. structured-logging (scoped in [[sp002]])
3. distributed-tracing (scoped in [[sp003]])
4. alerting (scoped in [[sp004]])
5. dashboards (scoped in [[sp005]])

Each capability has its own distinct `## providing`, its own `## api_surface`, its own consumer signature, and its own lifecycle. Per the AKM Feature schema's singletons (single `providing`, single `api_surface`, single `status`), the request cannot coherently fit a single `ft###`. The skill's `## Disambiguation` section calls this out explicitly: "observability stack" → N `ft###`, never one monolithic feature.

## sp### count and sizing reasoning
**5 sp### (one per ft### candidate).**

Per skill step 8: "N capabilities, independent non-trivial work each → N sp###, one per `ft###`. Each gets its own board lifecycle so they can ship independently."

The five capabilities are each independent, non-trivial subsystems:
- Metrics scraping = Prometheus client + endpoint exposition
- Structured logging = JSON schema + ship target (Loki/ES/file)
- Distributed tracing = OpenTelemetry SDK + collector + wire propagation contract
- Alerting = rule engine + notification routing (constrained by `adr0003`)
- Dashboards = provisioning + rendering + saved views (constrained by `adr0001`)

These are not "small scaffolding of well-understood shapes" — each is a real ship-by-itself unit. The default-to-one-sp### fallback was considered and rejected because the per-feature work is non-trivial and the features can ship independently with real value (e.g. structured logging alone is a win even if tracing slips).

## Categories cited
- `[[cat004]]` (observability) — primary on all 5 sp###
- `[[cat001]]` (security) — secondary on `sp004` (alerting routing carries sensitive content) and `sp005` (dashboard auth gate via `ft001`)
- `[[cat002]]` (data) — secondary on `sp002` (logging retention/indexing)
- `[[cat003]]` (infrastructure) — secondary on `sp001` (central scraper topology) and `sp003` (collector deployment + propagation header)

## ADRs cited
- `[[adr0001]]` (basic-auth) — cited in `sp004` (alert silencing UI must use ft001) and `sp005` (dashboard auth gate)
- `[[adr0002]]` (reports retention 90 days) — cited in `sp002` as a precedent for bounded log retention
- `[[adr0003]]` (no SMTP relay, smtplib direct) — **binding constraint** on `sp004` alerting notification path; flagged for possible spec-writing-time revisit because its `## consequences` lists pain points

## Wikilinks emitted in each `## problem` section
Every surveyed id that bears on the proposal landed as a wikilink, per the skill's reference discipline.

### sp001 (metrics)
- `[[ft001]]` `[[ft002]]` (dedup-considered)
- `[[im001]]` (consumer candidate)
- `[[cat004]]` `[[cat003]]` `[[cat001]]` (category picks)
- `[[adr0001]]` `[[adr0002]]` `[[adr0003]]` (surveyed; no conflict)
- `[[sp002]]` `[[sp003]]` `[[sp004]]` `[[sp005]]` (companion ft### scopes)

### sp002 (logging)
- `[[ft001]]` `[[ft002]]` (dedup-considered)
- `[[im001]]` (consumer candidate)
- `[[cat004]]` `[[cat002]]` `[[cat001]]` (category picks)
- `[[adr0002]]` (retention precedent)
- `[[sp001]]` `[[sp003]]` `[[sp004]]` `[[sp005]]` (companions)

### sp003 (tracing)
- `[[ft001]]` `[[ft002]]` (dedup-considered)
- `[[im001]]` (consumer candidate — report-run path crosses services)
- `[[cat004]]` `[[cat003]]` (category picks)
- `[[sp001]]` `[[sp002]]` `[[sp004]]` `[[sp005]]` (companions)

### sp004 (alerting)
- `[[ft001]]` `[[ft002]]` (dedup-considered)
- `[[im001]]` (surveyed, not a consumer — explicit non-match)
- `[[cat004]]` `[[cat001]]` (category picks)
- `[[adr0001]]` (silencing UI auth gate)
- `[[adr0003]]` (**binding** — smtplib path for email channel)
- `[[sp001]]` `[[sp002]]` `[[sp003]]` `[[sp005]]` (companions)

### sp005 (dashboards)
- `[[ft001]]` `[[ft002]]` (dedup-considered)
- `[[im001]]` (analyst dashboard, explicit non-match — different purpose)
- `[[cat004]]` `[[cat001]]` (category picks)
- `[[adr0001]]` (auth gate)
- `[[sp001]]` `[[sp002]]` `[[sp003]]` `[[sp004]]` (companions)

## Process notes
- Skill announced at start ("Using idea-feature skill to scope a new horizontal capability").
- Shared brainstorming basics from `infinifu:idea-brainstorming` were loaded; hard gate respected (no implementation, no code, no bd issues). The "work without stopping" instruction collapsed the multi-MC-question cadence into a single recommended-decomposition call.
- AKM hooks followed: read `ft`, `im`, `cat`, `adr`; **no direct `us` reads** (lifecycle contract). `us001/us002/us003` were inspected only via `[[im001]]`'s `solves` link — the transitive consumer-discovery path the skill prescribes.
- Dedup check: no observability `ft###` exists. `[[im001]]` (reports dashboard) flagged as an explicit non-match for sp005 — same word "dashboard" but different purpose/consumer.
- `[[adr0003]]` correctly carried forward as a binding constraint on `sp004` rather than silently ignored.

## What was NOT done
- No `ft###` files were minted — per the skill, this happens at `spec-writing`.
- No `us###` files created or read directly — lifecycle contract reads `im###` at this stage.
- No bd issues, no code changes, no commits.
