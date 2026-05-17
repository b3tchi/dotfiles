# Run notes — idea-feature eval (shared notifications)

## Summary

Loaded `idea-feature/SKILL.md` and the companion `idea-brainstorming/SKILL.md`. Read the AKM schema, product hub, and board. Walked the entry-specific checklist concretely against the seeded Acme zettels, then minted `docs/notes/spec/sp001.md` at `status: idea` with `## problem` populated, and added it to `docs/board.md` under `## idea`.

The eval harness's system reminder said to work without stopping for clarifying questions and make the reasonable call instead. Per that direction I proceeded past the design-approval gate rather than writing a `gate_reached.md` and stopping. The minted spec carries only `## problem` (the `idea` stage write per the AKM lifecycle); `## solution` / `## plan` / `## tasks` are intentionally absent because those are owned by `spec-writing` / `spec-refinement` / `spec-ready`. No `ft###` is minted — the skill is explicit that the feature is minted at spec-writing time once the boundary is settled.

## Zettels surveyed (by id)

- Categories: `cat001` (security), `cat002` (data), `cat003` (infrastructure), `cat004` (observability).
- Features: `ft001` (basic-auth), `ft002` (vault-secrets). No notifications feature exists — no dedup conflict.
- Implementations: `im001` (reports dashboard, consumes `ft001`). No `im###` captures the ad-hoc smtplib snippets — those live only in the three service `__init__.py` files.
- ADRs: `adr0001` (services auth via ft001), `adr0002` (reports Postgres 90d), `adr0003` ("No external SMTP relay — services use smtplib directly").
- Stories / personas: `us001` (analyst dashboard, done), `us002` (analyst date filter, ready), `us003` (platform-engineer credential rotation, ready); `pn001` (analyst — `primary_goals` include "Get notified when long-running reports finish"), `pn002` (platform-engineer).

## Path taken

Emitted `sp001` + board update. **No re-route.** Justification:

- **Not `idea-extend`.** No existing `ft###` covers notifications — the only related decision is `adr0003` (which is anti-shared-relay), not a feature. Re-routing to `idea-extend` requires a target `ft###`, and there isn't one.
- **Not `idea-implement`.** Three concrete consumers across two personas, plus a stated next-channel (Slack now, SMS plausible later). One-consumer "features" are `im###` glue per the skill's principle — that test is clearly cleared here.
- **Not `idea-hotfix`.** Nothing is broken in production; this is capability work.

`adr0003`'s direct contradiction is flagged in `sp001.## problem` as a supersession the spec-writing stage must handle when it mints the `ft###`. That keeps the lifecycle honest — ADRs are append-only, so the contradiction is recorded as a "spec-writing must produce a superseding ADR" obligation, not silently overridden here.

## Deviations from the skill's checklist

1. **Design-approval gate skipped per harness instruction.** The skill (and shared `idea-brainstorming`) prescribe one-question-at-a-time clarification, then 2-3 design approaches, then section-by-section approval before minting. The eval's system reminder explicitly said "work without stopping for clarifying questions … make the reasonable call." I proceeded to mint `sp001` with the design implied by the user's task statement (email + slack now, SMS plausible later, three concrete consumers). The `## problem` body is written defensively so the human reader can revise it before `spec-writing` runs.
2. **No `idea-extend` re-route despite `adr0003`.** `adr0003` constrains the area but isn't itself a feature, so `idea-extend` doesn't fit (it needs a target `ft###`). The contradiction is captured inside `sp001.## problem` as a supersession the next stage owns.
3. **Two H1 categories on the spec.** `sp001` H1 carries `[[cat003]] [[cat004]]`. AKM allows multiple `[[cat###]]` on specs (the schema says "one or more"); the picks reflect infrastructure (cross-service plumbing) + observability (alerting + send-metrics).

## Files emitted

- `docs/notes/spec/sp001.md` — new, `status: idea`.
- `docs/board.md` — modified, `sp001` listed under `## idea` with a one-paragraph "what's in flight" gloss.
- `.seed_manifest.txt` — incidental, pre-existing untracked file in the sandbox seed; staged because `git add -A` swept it. Not authored by this skill run.
