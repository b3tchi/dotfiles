# spec-retro sp003 — full retro summary

Using spec-retro skill to refresh the AKM graph post-merge.

## Setup

- `AKM_ROOT=/tmp/sr-iter3-new` (resolved via `akm-root`).
- `sp003.md` confirmed at `status: done` and listed under `docs/archive.md ## done`.
- `git log` shows a merge commit `c6cf513 merge sp003: reports smtp retry`
  on top of the seed. Diff against the merge-base is empty by construction
  (the seed lands code + spec together) — the shipped reality lives on disk
  and was treated as ground truth.

## Step 4–5 — diff vs spec, im### rewrite targets

`sp003.md` planned: "Wrap reports.sendReport() in retry-with-jitter,
matching auth and metrics services." What landed:
`src/services/reports/smtp.go` (the comment confirms the wrapper) plus
the pre-existing shared helper `src/lib/retry.go`. No deviation; nothing
in the spec was overturned. The `im003.md` body was thin (terse
proposed-stage prose). I rewrote `## approach`, `## data_model`,
`## api_surface`, and `## components` to match shipped reality with
explicit retry parameters (`3, 100*time.Millisecond`), a note that the
helper is also consumed by im001 and im002, and a clearer split between
story-specific glue (the SMTP closure) and the shared helper.

## Step 6 — ft### survey

The only registered Feature is `ft001` (basic auth). It is not touched
by this spec; no widening or supersession. The shared retry helper is
*not* yet a `ft###` — that's exactly what Step 7 evaluates.

## Step 7 — cross-im feature-extraction scan

### a. Candidate symbols from im003

From `im003.## components` and `## approach`:

- `src/lib/retry.go` — path
- `lib.RetryWithJitter` — named symbol; "3 attempts, 100ms base,
  exponential with jitter"
- `src/services/reports/smtp.go` — spec-specific glue (only this im###
  owns it, internal report closure). **Not a candidate** by the rule:
  "Internal domain logic that only this `im###` would ever call is not
  a candidate."

So the single capability candidate is `lib.RetryWithJitter` /
`src/lib/retry.go`.

### b. Cross-scan of every other `im*.md`

```text
ls $AKM_ROOT/docs/notes/im*.md
→ im001.md (SSO retry, done)
→ im002.md (Prometheus scrape retry, done)
→ im003.md (this one)
```

Reading each other Implementation's `## components` and `## approach`:

| Implementation | `## components` includes | `## approach` references |
|---|---|---|
| im001 — SSO refresh | `src/lib/retry.go` | "Wrap SSO refresh in `lib.RetryWithJitter` with 3 attempts, 100ms base. Exponential backoff with jitter" |
| im002 — Prom scrape | `src/lib/retry.go` | "Scrape collector now uses `lib.RetryWithJitter` ... Same retry-with-jitter pattern as the auth refresh" |
| im003 — SMTP send  | `src/lib/retry.go` | "Wrapped in `lib.RetryWithJitter` ... 3 attempts, 100ms base, exponential with jitter" |

Same file path. Same symbol name. Same call shape (`(3, 100ms, fn)`).
Cross-confirmed in source: `src/lib/retry.go` exposes
`RetryWithJitter(attempts int, base time.Duration, fn func() error) error`
and its own doc comment says: "Consumed by auth (SSO refresh), metrics
(Prometheus scrape), reports (SMTP)."

### c. Correlation-strength assessment

> **Strong correlation.** Three shipped `im###` (im001, im002, im003)
> consume the *same symbol* `lib.RetryWithJitter` via the *same file*
> `src/lib/retry.go` with the *same call shape* `(3 attempts, 100ms
> base, exponential+jitter, single closure)`. No per-consumer wrapping
> — each caller passes a domain-specific closure into the same generic
> signature; the helper itself is the abstraction layer, not a
> downstream adapter. Genuinely generic capability: nothing about
> retry-with-jitter is auth-, metrics-, or reports-specific.
>
> Correlation test: *"If I extract this to a `ft###` with one canonical
> signature, would im001, im002, im003 all consume it without
> per-consumer wrapping?"* Yes — they already do, because the helper
> is already shared. The Feature would just *name* what's already a
> shared building block.

This passes both gates: cross-scan turned up actual on-disk consumers
(im001 + im002, not speculation), and the consumers use the same shape
(same signature, same call pattern). The default bias toward
"vertical, leave glue in im###" does **not** apply — the helper is
horizontal by construction and used unmodified by three independent
Implementations.

### d. Candidate Features block

```text
Candidate Features:
- ft-extract `lib.RetryWithJitter` (src/lib/retry.go) — strong
  correlation across three shipped Implementations. Consumers:
    • im001 (SSO refresh) — ## components: src/lib/retry.go; ## approach
      names `lib.RetryWithJitter`, 3 attempts, 100ms base, exp+jitter.
    • im002 (Prometheus scrape) — ## components: src/lib/retry.go;
      ## approach names `lib.RetryWithJitter`, same pattern.
    • im003 (this retro) — ## components: src/lib/retry.go; same shape.
  Signature `RetryWithJitter(attempts int, base time.Duration,
  fn func() error) error` is generic, no per-consumer wrapping.
  Recommend minting `ft002` (retry-with-jitter) and updating im001 /
  im002 / im003 to list `## features: [[ft002]]`. **Human decides —
  not minted by this retro.**
- ft-extract `smtp send closure` from im003 — only im003 references it;
  story-specific glue. Not raised (single consumer).
```

### e. Human-verify discipline

Per the skill's Step 7e: all three constraints stack — (1) evidence, (2)
strong correlation, (3) human verification. (1) and (2) hold. (3) does
*not* hold yet — the user has not confirmed minting `ft002`. So:

- **I did NOT mint `ft002.md`.**
- **I did NOT edit `im001.md` to point at a not-yet-minted feature.**
- **I did NOT edit `im002.md` to point at a not-yet-minted feature.**
- **I left the candidate as a recommendation in this summary.**

If the user reads this and confirms, that's a separate `feature-write`
invocation plus a touch-up commit on im001/im002/im003 — not part of
this retro.

## Step 8–9 — ADRs and discovered scope

No ADRs were touched during execution; the choice to reuse the existing
retry helper had already been settled by im001/im002. Nothing to
supersede, nothing new to file. No bd task notes for this eval seed, so
no new `us###` drafts.

## Step 10–11 — writes and commit

Writes landed on main under `$AKM_ROOT`:

- `docs/notes/im003.md` — rewritten body to match shipped reality.
- `docs/product.md` — `>> [[im003]]` annotation added to the us003
  bullet under `## Stories`.

```bash
git -C "$AKM_ROOT" add docs/notes/im003.md docs/product.md
git -C "$AKM_ROOT" commit -m "feat(akm): retro sp003"
# → [main 3eb640f] feat(akm): retro sp003
```

No `adr####`, no `ft###`, no new `us###` were minted, so the subject
stays at the minimal `feat(akm): retro sp003` form (no `[+ …]`
brackets). im001.md and im002.md are intentionally untouched.

## Step 12 — bd epic close

No bd epic exists in this eval workspace, so `bd close` is skipped.
The retro reason that *would* be filed:

```text
Retro: sp003 SMTP retry shipped. Rewrote im003 to match shipped
reality (explicit 3/100ms params, helper attribution to im001+im002).
Candidates flagged: ft-extract `RetryWithJitter` (src/lib/retry.go)
— strong correlation across im001, im002, im003. Awaiting human
decision before minting.
```

## Step 13 — verification

- `git log -1 --oneline` → `3eb640f feat(akm): retro sp003` ✓
- Every retro write under `$AKM_ROOT/docs/...` ✓
- No `ft002.md` / `ft003.md` minted (see tree.txt) ✓
- `im001.md` / `im002.md` mtimes unchanged post-seed (see im-mtimes.txt) ✓
