# Run notes — idea-feature eval (iteration 2, eval 0)

## Surveying

**Dedup check (feature-read equivalent):** Read `ft001.md` (basic-auth)
and `ft002.md` (vault-secrets). Neither overlaps notifications. No
close match → proceed (no re-route to `idea-extend`).

**Consumers (story-read / implementation-read):**

- `us001` (done, analyst dashboard) — not a notif consumer itself,
  but the persona `pn001` lists "Get notified when long-running
  reports finish" as a primary goal → the `reports` service is a
  concrete consumer for ft-email-send.
- `us002` (filter reports) — not a consumer.
- `us003` (rotate credentials) — plausible alert consumer during
  rotation windows; flagged as plausible-not-committed.
- `pn001` analyst persona goal explicitly mentions email
  notifications — concrete consumer pull.
- `pn002` platform engineer — implicit alert consumer (metrics).

**Ad-hoc implementations (grep in `src/services/`):**

- `src/services/auth/__init__.py` — "Sends welcome emails by shelling
  to `mail` directly. Should migrate to a shared notifications
  feature once one exists." (Code already flags migration intent.)
- `src/services/metrics/__init__.py` — "Alert path currently writes
  to stdout + ad-hoc smtplib."
- `src/services/reports/__init__.py` — "Uses smtplib to email
  finished CSVs."

No existing `im###` cards capture these ad-hoc paths (only `im001`
for the dashboard).

**Categories (category-read):** cat001 (security), cat002 (data),
cat003 (infrastructure), cat004 (observability). Picked **cat003**
(cross-service plumbing — primary) and **cat004** (alerting paths —
secondary for the metrics consumer). Did not invent a new category.

**Binding ADRs (adr-read under picked categories):**

- `adr0003` under cat003 — "No external SMTP relay — services use
  smtplib directly. No retries, no templates, no dedup." This is
  the explicit constraint the proposal must overturn. Flagged in
  the sp###.problem: a new ADR superseding adr0003 will be needed
  at spec-writing stage before the ft### can ship.
- `adr0001` (cat001 security) — not directly binding.
- `adr0002` (cat002 data) — not directly binding.

## Granularity decision (ft### count)

Skill step 3 + key principle "atomic feature, atomic ft###" applied.

User asked for "shared notifications capability — email + slack now,
SMS plausible later." The AKM `ft###` schema is single-`providing` /
single-`api_surface` / single-`status`. Three send channels (SMTP,
Slack webhook, SMS gateway) cannot coherently share one
`api_surface` — each has a distinct invocation contract — and SMS
has a different lifecycle (deferred). Therefore: **NOT one
monolithic "notifications platform" ft###**.

**Decision: 2 ft### candidates now + 1 plausible later.**

- `ft-email-send` — atomic; replaces three ad-hoc smtplib snippets.
- `ft-slack-send` — atomic; new channel, first consumer is metrics.
- `ft-sms-send` — explicitly deferred (YAGNI); surfaced in sp###
  problem statement so the deliberate cut is visible.
- No notifications-router ft### at this stage — direct adapters
  compose cleanly for three consumers / two channels. Router
  becomes a separate ft### only when fan-out / templating / dedup
  patterns surface from real usage.

ft### are NOT minted in this skill — they are listed as candidates
in the sp001 `## problem` and will be minted at `spec-writing`
stage (per skill: minting at spec-writing avoids half-formed
features in the registry).

## Sizing decision (sp### count)

Skill step 8 applied. Two-or-three ft### candidates, but:

- They are **small scaffolding of well-understood shapes** (SMTP
  wrapper, Slack webhook wrapper — neither is novel work).
- The migration targets (`auth`, `metrics`, `reports`) all touch
  the same boundary and the same ADR-supersession decision.
- The work is coherent — one ADR flip unlocks both adapters; both
  adapters share `ft002` for secret retrieval; the three migrations
  ride together.

→ **One sp### (sp001)** listing all ft### candidates in
`## problem`. Split lands at task level during `spec-refinement` /
`spec-ready`. Per skill: "Default when unsure → one sp###;
splitting at task level is cheaper than splitting at sp### level."
Here it's not even unsure — the work is small and coherent.

Promoting to two sp### would fragment a coherent scoping pass
across two board lifecycles for no benefit; both would carry the
same ADR-flip dependency.

## Artifacts emitted

**New:**
- `docs/notes/spec/sp001.md` — status: idea, H1 carries
  `[[cat003]] [[cat004]] [[board]]`, body has `## problem` covering
  capability boundary, atomic-ft### split (2 + 1 deferred), why no
  router, plausible consumers (concrete `us###` / service today),
  migration targets (3 ad-hoc sites), inherited constraints
  (cat003 → adr0003 supersession dependency, cat004 no binding ADR,
  ft002 inherited for creds), explicit out-of-scope list, and the
  spec-writing intent. Footer `Index: [[board]]`.

**Modified:**
- `docs/board.md` — appended `[[sp001|shared notifications
  capability (email + slack)]]` under `## idea`; updated the
  preamble line.

**Not emitted (per skill design):**
- No `ft###` zettel — minted at spec-writing.
- No new `us###` — the persona goal on `pn001` is mentioned but
  formalizing the "notify when report done" AC story is a separate
  `idea-implement` pass for the analyst persona, not this skill.
- No new `cat###` — re-used existing cat003 / cat004.
- No new `adr####` — the adr0003 supersession is named as a
  spec-writing-stage write, not produced here.

## Gate behavior

No hard gate hit. The skill's hard gate is "no implementation /
code / bd issues before design approval". This skill produces the
design-stage zettel (sp001 in `status: idea` with `## problem`
populated) and a board update — those are the explicit writes of
stage 1 per the AKM hooks block. No implementation skill invoked,
no code touched, no bd issues created. The user instruction to
"work without stopping for clarifying questions" was honored by
making the reasonable call on every branch (granularity → 2 ft###;
sizing → 1 sp###; router → defer; SMS → defer; out-of-scope list
named explicitly).

## Skill adherence checklist

- [x] Announced at start (would in conversational use).
- [x] Loaded `idea-brainstorming` shared basics.
- [x] Dedup check vs ft001 / ft002.
- [x] Concrete consumers surfaced (auth, metrics, reports + pn001
      goal + plausible us003).
- [x] Granularity check produced N>1 → split into atomic ft###
      with explicit count and rationale.
- [x] Ad-hoc im### inventory (no existing im###; grepped src/
      directly — three migration targets named).
- [x] Categories picked from existing (cat003 + cat004); none
      invented.
- [x] Binding ADRs surveyed under picked categories; adr0003
      flagged as supersession dependency.
- [x] Migration sketch (one line per ad-hoc site).
- [x] Sizing call explicit (one sp###, default applies + work is
      small and coherent).
- [x] sp001 minted with `## problem` covering all required pieces.
- [x] board.md updated under `## idea`.
- [x] No ft### minted (per skill: deferred to spec-writing).
- [x] No implementation skill invoked.
