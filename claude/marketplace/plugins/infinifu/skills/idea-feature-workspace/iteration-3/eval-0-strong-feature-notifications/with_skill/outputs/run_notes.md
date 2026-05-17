# Run notes — idea-feature iteration-3, eval-0 (strong feature, notifications)

## Counts

- **ft### minted by this skill: 0** (correct — `idea-feature` does
  not mint `ft###`; minting is deferred to `spec-writing`).
- **ft### *candidates* identified for spec-writing to mint: 3**
  - `ft-notifications-router` (dispatch / templating / retry policy)
  - `ft-email-send` (smtplib MTA adapter)
  - `ft-slack-send` (slack webhook adapter)
- **Deferred / not minted: 1** — `ft-sms-send` flagged as
  "plausible-later, no committed consumer", explicitly excluded
  from this sp###.
- **sp### emitted: 1** (`sp001.md`, status `idea`).

## Sizing reasoning (one sp### vs N sp###)

Applied step 8 of the skill checklist. Three atomic capabilities, but:

1. Each is a small scaffolding of a well-understood shape (smtplib
   wrapper, slack webhook POST, dispatcher with channel registry).
2. The three consumers are small internal services already lined
   up for migration; no independent ship windows demanded.
3. The skill's default-when-unsure is one sp###; splitting at task
   level during `spec-refinement` is cheaper than splitting at
   `sp###` level.

→ One sp### with all three `ft###` candidates listed in
`## problem`. Promotion to N sp### is left as an explicit escape
hatch for spec-writing if any one channel proves non-trivial.

## Categories cited

- **[[cat003]] (infrastructure)** — picked as the H1 category for
  the spec and the eventual `ft###` cards. Cross-service plumbing.
- **[[cat004]] (observability)** — surveyed, explicitly *not* the
  feature's home (applies to the metrics consumer, not the
  capability itself). Mentioned in `## problem` for completeness.
- **[[cat001]] (security)** — surveyed, explicitly excluded (vault
  is consumed via existing [[ft002]], no new security surface).
- **[[cat002]] (data)** — surveyed, explicitly excluded (capability
  is intentionally stateless v1; audit-log would be a follow-up
  ft###, not a widening).

## ADRs cited

- **[[adr0003]]** — *conflicting* ADR. "No external SMTP relay —
  services use smtplib directly." Spec calls out that minting a
  shared notifications feature implies superseding adr0003 at
  spec-writing time, and pre-stages the replacement-ADR decision
  text. This is the lifecycle contract working as intended:
  catching the duplication-mitigation half of stage-1 goals before
  silent conflict.
- **[[adr0001]]** — surveyed, explicitly out of scope (auth
  decisions don't bind notifications).
- **[[adr0002]]** — surveyed, explicitly out of scope (postgres
  retention doesn't bind a stateless capability).

## Wikilinks emitted in `## problem` (reference discipline check)

Per the iteration-3 reference discipline ("every surveyed id that
bears on the proposal lands in `## problem` as a wikilink"):

- Features (dedup-considered): [[ft001]], [[ft002]]
- Implementations (survey result): [[im001]] (only existing im;
  notification logic is in non-im### service code, called out
  by path)
- Categories: [[cat001]], [[cat002]], [[cat003]], [[cat004]]
  (all four surveyed; the picked one + the three explicitly-excluded
  ones all linked, so the survey itself is auditable from the
  problem statement)
- ADRs: [[adr0001]], [[adr0002]], [[adr0003]] (all three surveyed;
  the conflicting one + the two explicitly-excluded ones linked)

Total surveyed ids appearing as wikilinks in `## problem`: **9**
(2 ft + 1 im + 4 cat + 3 adr) + 1 board citation in the H1
(`[[board]]`) and 1 footer citation.

## Hard gate

Honored. No implementation skill invoked, no code written, no bd
issues opened. Only `sp###` zettel + board update were written.

## Granularity check (step 3)

The user's phrasing ("a shared notifications capability — email +
slack now, SMS plausible later") packs at minimum two atomic
capabilities (email-send, slack-send) and implicitly a third
(router/dispatch). The `ft###` schema's single-`providing` /
single-`api_surface` / single-`status` constraint forces the
N-feature answer; documented in the `## problem` "Capability
boundary" block so a future reader sees the decomposition logic.

## Story stage gate (lifecycle reads)

Skill text iteration-3 says `idea-feature` reads `ft / im / cat /
adr` only — *no* `us` reads. Honored: surveyed `im001` for
consumers, did not invoke story-read / story-find. Confirmed the
two existing stories ([[us001]], [[us002]], [[us003]] from
`product.md`) are not notification consumers in the AKM graph —
notification paths today live as raw service code outside any
`im###`. This is logged in the spec ("No existing im### carries
notification logic today").

## User input

None solicited (instructions said work without stopping). Reasonable
calls made on:

- Category pick (cat003 over cat004) — defended in spec.
- SMS deferral — defended (no committed consumer, paid vendor risk).
- One sp### vs three sp### — defended via step-8 reasoning.
- adr0003 supersession path — staged, not executed (correct, it's
  a spec-writing decision, not an idea-stage one).
