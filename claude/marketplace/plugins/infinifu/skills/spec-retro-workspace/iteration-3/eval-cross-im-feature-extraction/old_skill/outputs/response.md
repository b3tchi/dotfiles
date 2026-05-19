# spec-retro sp003 — baseline run

Using spec-retro skill to refresh the AKM graph post-merge.

## Preconditions verified

- `sp003.status: done`, footer `Index: [[archive]]` — work-merge precondition met.
- Merge commit visible: `368b834 merge sp003: reports smtp retry` against base `8a03c95`.
- `im003.status: accepted`.

## Diff vs spec

Read `git log 8a03c95..368b834` (single merge commit, no `--stat` output meaning the merge brought in pre-staged files from the seed). Walked the spec tasks against shipped code:

| sp003 task | Shipped at | Match |
|---|---|---|
| Add SMTP retry wrapper | `src/services/reports/smtp.go` consumes `lib.RetryWithJitter` | yes |
| Update reports service to use it | `reports.sendReport` wrapped | yes |

No deviations from the plan. The pre-existing `src/lib/retry.go` was consumed as-is — no new helper minted.

## Im003 rewrite

The `## approach` already described shipped reality (the spec was tight). Tightened it for AKM persistence:

- Made the call site explicit (`reports.sendReport` wraps the relay call).
- Added wikilinks to `[[im001]]` and `[[im002]]` since the narrative names the auth and metrics services — those are siblings consuming the same helper, and the persistent card should carry typed back-references rather than prose-only mentions.
- Annotated `## components` to mark which file is the call site vs the shared helper, and noted the helper's other consumers.

`## data_model` and `## api_surface` kept; no schema, internal-only API. No status flip (work-merge already set `accepted`).

## ADRs

No decisions shifted during execution. The retry semantics (3 attempts, 100ms base, exponential with jitter) match what auth and metrics already do. No new ADR minted. No existing ADR superseded. (Note: there is no ADR for the retry policy in the seed — that's a pre-existing gap, not something sp003 introduced.)

## Features

No `## features` block on im001/im002/im003 — none of them consume an `ft###`. `lib.RetryWithJitter` is a bare Go helper, not a registered Feature zettel. No `ft###` updates this retro.

## Discovered scope

bd notes not available in seed; spec was small; no defer-flags noted in the merge commit. No new `us###` drafts emitted.

## Candidate Features (step 7 — for human decision)

Walked the rewritten im003 `## components` list and `## approach` narrative for code that named existing or in-flight `im###` would also consume.

```
Candidate Features:

- ft-extract `retry_with_jitter` from src/lib/retry.go
  Signal: im003 `## approach` explicitly names [[im001]] (auth SSO refresh)
          and [[im002]] (Prometheus scrape) as consumers of the same retry
          shape. That's three shipped Implementations already wrapping
          calls in `lib.RetryWithJitter` with identical parameters
          (3 attempts, 100ms base, exponential + jitter).
  Per signal table: "Two+ shipped or in-flight im### already need this
                     code → extract to ft### (real reuse)".
  Proposed surface:
    - ## providing: bounded retry with exponential backoff + jitter for
      transient-failure call sites
    - ## api_surface: RetryWithJitter(attempts int, base time.Duration,
                                     fn func() error) error
    - ## components: src/lib/retry.go
    - ## sample: see auth.refreshToken, scraper.collect,
                 reports.sendReport
  Action: human to confirm minting `ft002` and back-linking im001/im002/
          im003 `## features: [[ft002]]`. Not minting silently — the
          AKM rule is vertical-over-horizontal until reuse is confirmed.
```

This block is surfaced for human decision per the baseline's pragmatic-not-aggressive policy. Did **not** mint `ft###` automatically.

Caveat on the cross-scan: the signal for this candidate came from the *prose* in im003's `## approach` (which named auth + metrics by service name), not from an explicit walk of `im001.md` and `im002.md` files. The baseline checklist does not require opening sibling `im###` files; step 7 scans the rewritten im### body. A run that *did* open siblings would have confirmed the same conclusion from their `## components` lists (both list `src/lib/retry.go`), and would have been more robust against the case where the prose forgot to name them. For this seed the conclusion lands either way.

## Commit + bd close

Stage:

```bash
git -C "$AKM_ROOT" add docs/notes/im003.md
git -C "$AKM_ROOT" commit -m "feat(akm): retro sp003"
```

(No ADRs/ft/us/product.md changes — minimal retro, im003 only.)

bd epic close:

```
bd close <epic-id> --reason "Retro: reports SMTP retry shipped. Rewrote
im003 (tightened approach + back-links to im001/im002). 0 new ADRs /
0 ft updates / 0 us drafts. Candidate flagged: ft-extract
retry_with_jitter — third shipped consumer of src/lib/retry.go makes
real reuse the signal."
```

(bd not actually executed in this eval workspace.)

## Summary

- **Did you cross-scan other im### files?** No, not explicitly. The baseline checklist (step 7) walks the rewritten im### body, not sibling files. The candidate was surfaced from prose in im003's `## approach` that already named im001 and im002.
- **Did you produce a Candidate Features block?** Yes — quoted above.
- **What did you do with the apparent retry-helper reuse?** Flagged it as a candidate `ft###` extraction for human decision (signal: 3 shipped consumers, per the table threshold). Did not mint silently. Did not back-link `## features: [[ft###]]` on im001/im002/im003 — that would presuppose the human's decision.
