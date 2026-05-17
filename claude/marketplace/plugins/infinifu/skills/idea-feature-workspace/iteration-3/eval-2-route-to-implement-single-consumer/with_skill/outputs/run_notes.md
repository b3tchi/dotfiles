# Run notes — eval-2-route-to-implement-single-consumer (with_skill)

## Decision

**Re-routed from `idea-feature` to `idea-implement`.** The Disambiguation rule
in `idea-feature/SKILL.md` fires on the first read:

> Capability that serves exactly one story → re-route to `idea-implement` (it's
> `im###` glue, not `ft###`).

The user's ask explicitly names one persona ([[pn002]] platform-engineer) and
one trigger (quarterly, on legal request). No multi-consumer dimension exists
in the request. Per the Key Principle "A feature with one consumer is not a
feature," the right entry type is `idea-implement`, which will mint a new
`us###` for the platform-engineer and a fresh `im###` consuming existing
features.

## Zettel ids

**No new zettel ids minted.** The skill halts at the Disambiguation gate
before any `ft###` / `sp###` / `us###` / `im###` write. The eventual writes
will happen under `idea-implement`:

- new `us004` (next free) — platform-engineer's deletion-proof story
- new `sp001` (next free) — captures `## problem` referencing the new story,
  [[pn002]], [[adr0002]], [[cat002]], [[cat001]]
- new `im002` (next free) — solution shape, consuming [[ft002]]

(IDs above are predictions for `idea-implement`'s downstream work, not
written by this run.)

## Surveyed ids (cited in route_decision.md)

Features [[ft001]] [[ft002]]; Implementation [[im001]]; Stories [[us001]]
[[us002]] [[us003]]; Personas [[pn001]] [[pn002]]; Categories [[cat001]]
[[cat002]] [[cat003]] [[cat004]]; ADRs [[adr0001]] [[adr0002]] [[adr0003]];
Hubs [[product]] [[board]].

The binding ADR is [[adr0002]] (90-day Postgres retention); the natural home
category is [[cat002|data]] with [[cat001|security]] secondary for the audit
angle.

## Files written

- `sandbox/route_decision.md` — Disambiguation citation + survey grounding +
  re-route action.

No `docs/board.md` edit, no new `sp###`, no new `ft###`. The skill halted at
the gate as designed.

## Skill performance notes

The `idea-feature` skill's Disambiguation block + the "A feature with one
consumer is not a feature" Key Principle made this an unambiguous re-route.
Both the Disambiguation list and the Key Principles call out the single-
consumer trap explicitly, so the decision point is clearly signposted. The
"Identify consumers via `im###`" step (#2 in the checklist) reinforces the
red flag: "Zero or one plausible consumer is a red flag — features are
reusable by definition."
