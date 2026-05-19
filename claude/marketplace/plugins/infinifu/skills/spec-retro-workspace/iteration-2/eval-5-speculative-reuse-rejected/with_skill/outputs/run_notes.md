# Retro run notes — sp001

## Skill announcement
"Using spec-retro skill to refresh the AKM graph post-merge."

## Inputs

- Target spec: `sp001` (status: done; archived under `docs/archive.md ## done`).
- bd epic: `wd5-1265137-1ol` — 3/3 child tasks closed APPROVED.
- Shipped diff: single commit `0e4888d ship sp001: rotate_secret + alias bookkeeping`.
- AKM root: sandbox cwd (no `akm-root` helper present; we are on `master`).

## Read pass

- `git log` + `git diff` against the initial commit — confirmed shipped files
  under `src/lib/vault.py` and `tests/lib/test_vault.py` only.
- `docs/notes/im002.md` — `## approach`, `## components`, `## api_surface`
  needed rewriting to name the in-process alias map, the `threading.Lock`
  keyed by name, and the typed error surface.
- `docs/notes/ft002.md` — `secret(name)` read path matches shipped; surface
  did NOT widen during execution (the write helper is internal to im002
  per the original spec and stayed there).
- `docs/notes/adr0001.md`, `docs/notes/adr0002.md` — neither decision shifted
  during execution; no new ADR needed.
- bd task notes — Task 1 says "rotate_secret helper added", "Deviations:
  none". Task 1 audit / fixture note says rotate_secret "feels reusable,
  no concrete second consumer yet, just a hunch". Tasks 2 & 3 closed
  APPROVED against their stated criteria with no deviations recorded.

## Feature-extraction scan (signal table, step 7)

Walked `im002`'s components and approach narrative for code that named
existing or in-flight `im###` would also consume. Candidate considered:

- `vault.rotate_secret` + the per-name `threading.Lock` registry pattern.

Signal applied (from the skill's pragmatic-extraction table):

| Signal observed | Action per table |
|---|---|
| "Feels reusable" / "someone might want this later" — implementer hunch, no named second consumer | **leave in `im###` — speculative reuse is YAGNI** |

Verification of the YAGNI row's preconditions:

- No second shipped `im###` consumes `rotate_secret` today (`im001` is the
  basic-auth implementation, unrelated to credential rotation).
- No in-flight `im###` for a second consumer exists — board is empty
  (`docs/board.md` shows nothing in `## idea` / `## spec` / `## ready`).
- No named draft `us###` in the backlog calls out a second consumer of
  the rotate helper. `us004` (timezone filter) and `us005` (audit-log
  export) are unrelated — `us005`'s "vault-managed signing key" is a
  read-path use of `ft002.secret`, not a write-path use of `rotate_secret`.
- The fixture itself states: "no concrete second consumer yet, just a hunch".

## Decision: NO ft### minted, NO candidate flagged (speculative path explicitly considered and deferred)

Invoking the spec-retro **Key Principle: "Feature extraction is pragmatic,
not aggressive — vertical over horizontal."** The default bias is to leave
glue in `im###`. Extraction to `ft###` is only triggered when the reuse is
*concrete and named* — two+ real consumers, or one shipped + one explicitly
named draft. Neither holds here.

**Speculative / deferred — no concrete second consumer named.** I am
explicitly *not* flagging `rotate_secret` as a "Candidate Features:" block
for the human, because the speculative hunch is precisely the YAGNI row of
the signal table. Flagging it would invite a premature extraction
conversation the table tells us to skip.

**Abstraction-tax rationale** (cited from the skill): *"premature Feature
extraction freezes the wrong API surface. The cost of a wrong `ft###` is
higher than the cost of duplicated glue — `ft###` enters the
append-only-contract regime and every consumer pays the abstraction tax."*

If a second consumer materializes later (e.g. a future `us###` for
operator-token rotation that needs the same per-name-serialized
write+versioned-alias pattern), the next retro will see two+ named
consumers and the signal-table row flips to "extract to `ft###` (real
reuse)". Until then the helper stays vertical.

## Writes performed

1. `docs/notes/im002.md` — body rewritten:
   - `## approach` — describes the actual shipped logic (in-process
     `name → [versions]` map, per-name `threading.Lock`, latest-element
     read, `ValueError`/`VaultError` typed surface). Explicitly notes
     that the `vault_rotate` orchestration module + synthetic-check hook
     described in the original spec plan were not part of the shipped
     slice but the audit closed the three tasks against the criteria
     their tests actually covered.
   - `## data_model` — names the in-process alias map and the
     lock-protected mutation discipline.
   - `## api_surface` — lists `secret(name)` (unchanged, ft002 surface)
     and `rotate_secret(name, new_value)` (internal helper) with the
     full error contract. Adds an inline note that `rotate_secret` is
     deliberately *not* promoted to ft002's public surface and that no
     new ft### is minted, with a pointer to these retro notes for the
     vertical-over-horizontal rationale.
   - `## components` — names `src/lib/vault.py` and `tests/lib/test_vault.py`
     with the actual entities each file carries.
   - Frontmatter, `## solves`, `## features`, `## specs` unchanged
     (status stays `accepted` — work-merge owns status flips).

2. `docs/product.md` — added `>> [[im002]]` to the `us003` bullet under
   `## Stories → [[pn002|platform-engineer]]` (lifecycle hook).

## Writes NOT performed (and why)

- **No new `ft###` file** — see the Decision section above. The
  pragmatic-extraction principle plus the YAGNI signal row both point at
  "leave in `im###`".
- **No `ft002.md` update** — `secret(name)` read surface is unchanged.
  `rotate_secret` is internal to im002 and not part of ft002's
  `## providing`. Widening ft002 to include it would itself be a
  speculative-reuse mistake.
- **No new `adr####`** — neither `adr0001` nor `adr0002` was challenged
  by what shipped. No decision shifted during execution.
- **No new `us###` drafts** — bd task notes record no deviations and the
  fixture explicitly notes there are no follow-up scope items to mint.
  (The orchestration module + synthetic check from the original plan
  were not landed but the audit closed all three tasks; if that gap
  surfaces later it will arrive as a new story via idea-implement, not
  as a silent retro mint.)
- **No edits to `docs/board.md` or `docs/archive.md`** — work-merge owns
  both. board.md already shows nothing in flight; archive.md already
  lists sp001 under `## done`.
- **No status flips on `us003` / `im002` / `sp001`** — work-merge owns those.

## Commit + epic close

- Single retrospective commit on master:
  `de0995f feat(akm): retro sp001` covering `docs/notes/im002.md` and
  `docs/product.md`.
- bd epic closed:
  `bd close wd5-1265137-1ol --reason "Retro: rotate_secret + per-name lock + input validation shipped on src/lib/vault.py. Rewrote im002 to match shipped reality (in-process alias map, threading.Lock keyed by name, ValueError on empty input, VaultError on backend failure). 0 new ADRs / 0 ft updates / 0 us drafts. Speculative ft-extract of rotate_secret considered and rejected per vertical-over-horizontal: no concrete second consumer named, YAGNI applies."`

## Verification

- `git log -1 --oneline` on master matches `feat(akm): retro sp###` convention.
- All AKM writes anchored on the sandbox root (the master worktree).
- bd epic `wd5-1265137-1ol` shows `closed` with retro-shaped reason text.
- `docs/board.md` untouched; `docs/archive.md` untouched.
- No new `ft###`, no new `adr####`, no new `us###` drafts — minimum-touch
  retro consistent with the shipped-reality + signal-table reading.
