# Run notes — eval-3 granularity decompose observability (with_skill)

## Outcome summary

- **ft### count:** 5 candidates named in `sp001 ## problem` (metrics-emission, structured-logging, distributed-tracing, alerting-rules, dashboards). Not minted yet — `idea-feature` defers `ft###` creation to `spec-writing` per the skill.
- **sp### count:** 1 (`sp001`). Single deliverable workstream listing all 5 `ft###` candidates inline.
- **Categories:** `[[cat004]]` (observability, primary) and `[[cat003]]` (infrastructure, secondary — alert routing + dashboard provisioning are cross-service plumbing).
- **Gate:** Hard gate (design approval) was bypassed per user instruction "work without stopping for clarifying questions." Documented in `sandbox/gate_reached.md`.

## (a) ft### count + naming

5 distinct `ft###` candidates, named in `sp001 ## problem`:

| # | Candidate name (descriptive, no id yet) | `## providing` shape | `## api_surface` shape | Consumers |
|---|---|---|---|---|
| 1 | `metrics-emission` | counters/gauges/histograms + scrape endpoint | `Counter("foo_total").inc()` | auth, metrics, reports |
| 2 | `structured-logging` | JSON formatter + correlation-id propagation | `get_logger(__name__)` | auth, metrics, reports |
| 3 | `distributed-tracing` | OTel SDK wrapper + collector export | `with tracer.start_span("name"):` | auth, metrics, reports |
| 4 | `alerting-rules` | rule contract + router | rule YAML + router endpoint | auth, metrics, reports |
| 5 | `dashboards` | dashboard-as-code provisioning | dashboard JSON + provisioning cmd | auth, metrics, reports |

Why 5 and not 1: each row above has a different `providing` paragraph, a different `api_surface`, different consumer-side ergonomics, and could plausibly carry its own `status` lifecycle. The `ft###` schema is single-`providing` / single-`api_surface` / single-`status`, so they cannot coherently fit one zettel.

## (b) sp### count + sizing reasoning

**Chose 1 sp### (sp001), not 5.**

The skill's step-8 sizing rule offers two branches:
- "N capabilities, small scaffolding of well-understood shapes → one sp###"
- "N capabilities, independent non-trivial work each → N sp###"
- "Default when unsure → one sp###"

The per-feature work here is non-trivial AND independent (the "promote to N" condition is partially met), but the following considerations tipped the call toward one:

1. User framed it as a **unified roll-out** replacing today's mess — five independent specs would lose the unifying design pass.
2. **No backlog story is blocked** on any individual capability — there is no urgency forcing earliest-ship for tracing vs latest-ship for dashboards.
3. **Sequencing** — dashboards and alerting functionally depend on metrics shipping first; a single coherent plan keeps that sequencing legible.
4. The skill explicitly favors the default: **"merging later is harder than splitting later."** Splitting at the task level during `spec-refinement` is cheap; reuniting five independent specs after the fact is not.

Plan: `sp001` lists all 5 `ft###` candidates in `## problem`. At `spec-writing` time, the 5 `ft###` cards get minted and `sp001 ## solution` references each. At `spec-refinement`, tasks split per-feature; if any one of the five inflates beyond the rest, it can be peeled off into its own `sp###` then (peel at task granularity is cheap).

## (c) Categories picked

- **`[[cat004]]` — observability (primary).** All five capabilities are observability concerns by definition. This is the most accurate primary bucket.
- **`[[cat003]]` — infrastructure (secondary).** Alerting routing and dashboard provisioning are cross-service plumbing / deployment concerns — they fit cat003 as well. Included in the H1.

Skipped: `[[cat001]]` (security — no auth/secret-handling concerns) and `[[cat002]]` (data — observability data has its own retention, but Reports-style schema isn't relevant).

## (d) Gate hit

**Yes — the hard gate was bypassed per explicit user instruction.**

The shared `idea-brainstorming` process requires:
1. One-question-at-a-time clarification (capability boundary, consumers, constraints)
2. A 2-3 design-approach proposal
3. Section-by-section approval before emitting any zettel

The user instructed "work without stopping for clarifying questions; make the reasonable call and continue." I proceeded past the gate. `sandbox/gate_reached.md` records what was bypassed and what would normally be asked.

Open questions that would normally be MC'd before emitting:
- Tracing backend (Jaeger / Tempo / Honeycomb / build-internal)
- Alert routing target (given `adr0003` constrains email-only via direct smtplib — does the alerting feature inherit or supersede that ADR?)
- Log retention window and shipping target (file rotate / Loki / ELK)
- Whether dashboards ride in the same repo (dashboard-as-code) or in a separate Grafana provisioning repo

These open questions land in `sp001 ## problem` implicitly via the feature descriptions and the ADR-binding paragraph; they will need explicit resolution at `spec-writing`.

## Files emitted

**New:**
- `docs/notes/spec/sp001.md` — the spec at `status: idea`.
- `gate_reached.md` — gate bypass note (sandbox root).
- `docs/notes/spec/` — new directory (didn't exist in seed).

**Modified:**
- `docs/board.md` — appended `[[sp001|unified observability stack ...]]` under `## idea`; updated the lede paragraph.

**Not modified (deliberate):**
- No new `ft###` files. The skill defers `ft###` minting to `spec-writing`.
- No new `cat###` files. `cat004` (observability) already existed in the seed.
- No new `adr####`. Decisions like tracing-backend / alert-router-target are surfaced as open questions in `sp001`; ADRs land at `spec-writing` per the skill.
