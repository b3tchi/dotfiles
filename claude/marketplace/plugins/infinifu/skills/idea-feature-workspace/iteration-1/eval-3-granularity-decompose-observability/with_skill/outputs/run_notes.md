# Run notes — eval-3 granularity-decompose-observability (with_skill)

## Skill loaded

- `infinifu:idea-feature` — direct entry point for AKM "feature add".
- Loaded shared basics from `infinifu:idea-brainstorming` per the
  skill's preamble.
- Loaded AKM schema (`docs/notes/akm.md`), product hub (`docs/product.md`),
  board hub (`docs/board.md`).

## Surveying performed (concrete, grounded — no invented ids)

1. **`feature-read` (dedup):** read `ft001` (basic-auth) and `ft002`
   (vault-secrets). Neither touches observability — clean greenfield,
   no re-route to `idea-extend`.
2. **`category-read`:** `cat004` (observability) exists and is the
   exact fit — *"Metrics, logging, tracing, alerting paths"*. `cat003`
   (infrastructure) is the secondary fit for cross-service plumbing.
   No new category needs minting.
3. **`adr-read` under cat004 + cat003:** `cat004` has zero binding
   ADRs (clean slate, which is itself a flag). `cat003` carries
   `adr0003` (no SMTP relay, smtplib direct) — relevant analogue for
   the alerting sub-capability when it needs to email on-call.
4. **`story-find` / `story-read`:** consumers are `us001` (done,
   reports dashboard — logs/dashboards), `us002` (ready — same),
   `us003` (ready, platform — explicitly needs synthetic check ≈
   metrics + alerting). Healthy consumer count, no "feature with one
   consumer" anti-pattern.
5. **`implementation-read` + repo inspection:** read README and
   listed `src/`. Migration targets are `src/services/metrics/`
   (ad-hoc Prometheus + stdout alerts), `src/services/reports/` and
   `src/services/auth/` (stdout logs), and `im001` (no obs at all on
   the dashboard implementation).

## Conclusion on granularity / splitting

**This is not one feature.** The ask bundles 5 distinct horizontal
capabilities (metrics scraping, structured logging, distributed
tracing, alerting, dashboards). The AKM `Feature` schema (single
`## providing` paragraph, single `## api_surface`, single `status`)
literally cannot carry this bundle coherently. The skill's own
principle — features are atomic reusable building blocks — forbids
the framing. Each of the 5 has its own consumer surface, ADR
attractors (sampling, retention, cardinality, alert routing), and
ship timeline.

**Recommended re-shape:** one `sp###` at `## idea` stage with a
program-shaped `## problem` that explicitly enumerates the up-to-5
candidate `ft###` cards to be minted at spec-writing time. The
skill's deferred-ft### rule ("the `ft###` is not minted by this skill
— the capability boundary is still under discussion. Minting at
`spec-writing` time avoids a half-formed feature ending up in the
registry") is exactly the rule for this situation.

**Two alternatives presented in gate_reached.md:** (B) five separate
`sp###` cards, one per capability; (C) foundation-first — one ft###
bundling emit-side libs, separate sp### for tracing/alerting/
dashboards later.

## Deviations from skill checklist

None. Followed steps 1-5 of the entry-specific checklist (dedup,
consumers, ad-hoc inventory, categorize, ADR survey). Stopped before
step 6 (migration sketch finalization) and step 7 (mint `sp###`)
because:

- The hard gate from `idea-brainstorming` forbids implementation
  action — including minting `sp###` — before design approval.
- The split-vs-bundle decision is load-bearing for the `sp###`
  `## problem` body; minting first would encode the bundled framing
  and force a body rewrite later (anti-pattern).
- The user instruction was "make the reasonable call and continue".
  The reasonable call is to surface the granularity finding plus a
  recommended re-shape and three options, rather than either (a)
  silently mint a malformed bundled `sp###` or (b) silently mint
  five `sp###` cards without flagging that the request asked for one
  feature.

The artifact emitted is `sandbox/gate_reached.md` — the exact
artifact the task instructions ask for when stopping at the first
hard gate. It includes the survey results, the granularity finding,
the recommended re-shape, three options to present, and the one MC
question that would unblock the next step.

## Files emitted

- `sandbox/gate_reached.md` (new) — hard-gate stop document.

No `sp###` minted, no `docs/board.md` edit. No `ft###` minted (per
skill design). No code or bd issues touched.
