# Run notes — baseline (no skill applied)

## Task

Scope a shared notifications capability (email + slack now, SMS
plausible later) using what would have been the `infinifu:idea-feature`
skill flow. Working dir: seeded Acme sandbox.

## What I read

- `README.md` — three services (auth, metrics, reports), Python+Postgres
- `docs/product.md` — hub: stories per persona, features, ADRs by cat
- `docs/board.md` — empty (nothing in flight)
- `docs/archive.md` — empty (nothing shipped via spec model yet)
- `docs/notes/akm.md` — the knowledge model schema (most important
  read; defined how `sp###` / `ft###` / `im###` lifecycles work and
  what gets captured at idea stage vs spec stage)
- `docs/notes/ft001.md`, `ft002.md` — existing reusable features
  (basic-auth, vault-secrets) — confirmed ft### numbering and shape
- `docs/notes/cat001..cat004.md` — taxonomy buckets (security, data,
  infrastructure, observability). cat004 was unused but defined.
- `docs/notes/adr0001..adr0003.md` — especially **adr0003** which
  explicitly mandates "no relay, services use smtplib directly" and
  flags the three-copy/paste drift as a known consequence. This is
  the load-bearing ADR for the new spec — it must be superseded at
  spec stage.
- `docs/notes/us001..us003.md`, `pn001.md`, `pn002.md`, `im001.md` —
  to confirm existing ids and find any story that ought to anchor a
  notification spec. pn001 analyst's primary goal "get notified when
  long-running reports finish" had no backing story — I created one.
- `src/services/auth/__init__.py`, `metrics/__init__.py`,
  `reports/__init__.py` — confirmed the three smtplib snippets the
  user described.

## What I produced

1. **`docs/notes/us004.md`** — fresh `draft` user story for pn001
   analyst: "get notified when long-running reports finish." This
   gives the notifications spec a concrete `solves: [[us004]]` target
   per the AKM requirement that specs back-link a story.

2. **`docs/notes/spec/sp001.md`** — new spec at `idea` stage carrying
   only the `## problem` section (per AKM lifecycle: idea→spec→ready→
   done; idea stage populates problem only, solution/plan/tasks come
   later). Problem captures:
   - The three smtplib snippets and their service paths.
   - The two new pressures: slack now, SMS later (plausible, not
     committed).
   - A channel-by-service matrix.
   - Explicit `adr0003` tension that has to be revisited (a new ADR
     superseding it will be written at spec stage, not now).
   - Non-goals at idea stage (templating, sync/async, retry, dedup,
     SMS provider) to keep idea capture honest.
   - H1 categories: `[[cat003|infrastructure]]` and
     `[[cat004|observability]]`. Deliberately did **not** claim
     `[[cat001|security]]` — credentials/secrets may surface later.

3. **`docs/product.md` — updated**:
   - Added `us004` under pn001's stories.
   - Added a `### [[cat003|infrastructure]]` section under the ADR
     index listing `adr0003` (it was previously omitted — found while
     surveying).
   - Added `[[cat004|observability]]` to the flat Categories chain at
     the bottom (it existed as a zettel but wasn't indexed on the
     hub).

4. **`docs/board.md` — updated**: `sp001` listed under `## idea`
   (per AKM: status-driven section placement).

## What I deliberately did NOT do

- **Did not mint a new `ft###` Feature zettel.** Per AKM, the feature
  is minted at spec stage when the solution shape is chosen — the
  idea-feature entry only captures the *problem* under `sp###`. So no
  `ft003.md` written; the spec problem section explicitly names "mint
  a new ft### at spec stage" as the intent.
- **Did not write an `im###` Implementation.** Implementation is
  drafted alongside the spec body once we know the solution shape.
- **Did not write the superseding ADR for `adr0003`.** That is a
  spec-stage deliverable; flagged in the problem section as a known
  obligation.
- **Did not touch service code.** No refactor at idea stage.

## Key findings worth flagging upstream

- `adr0003` is the load-bearing constraint to revisit; without an
  override it blocks the consolidation.
- `docs/product.md` had two pre-existing index gaps the survey
  surfaced: `adr0003` wasn't under any category heading, and `cat004`
  wasn't on the Categories chain. Both fixed.
- pn001 analyst's "get notified when reports finish" goal had no
  backing story — captured as `us004` so the spec anchors to a real
  backlog item rather than being purely an internal refactor.
- The auth-service welcome email is the weakest consumer (low volume,
  transactional) — flagged as "maybe carve out of first cut" in the
  non-goals so the spec stage can decide scope-of-MVP.
