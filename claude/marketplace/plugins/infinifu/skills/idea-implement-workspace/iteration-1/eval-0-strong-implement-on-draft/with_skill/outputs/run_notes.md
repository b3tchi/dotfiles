# idea-implement run notes (us003 → sp001)

## Skill executed

`infinifu:idea-implement` on `us003 (rotate service credentials without downtime)`.

## Pre-flight gate check

- `us003.md` exists at `status: draft` → entry condition for `idea-implement` is met.
- `## role`, `## want`, `## because`, `## acceptance_criteria` all populated.
- Persona `[[pn002|platform-engineer]]` resolves to `docs/notes/pn002.md`,
  status `validated`.
- All three acceptance criteria are testable (rotation-while-running,
  5-minute overlap, zero-5xx synthetic check) → no hard-gate hold;
  promotion to `ready` is allowed.

## Surveyed AKM context

Read every typed zettel in `docs/notes/` to ground the proposal in
real ids — no invented zettels.

| Bucket | Surveyed ids | Verdict |
|---|---|---|
| Story (target) | `us003` (draft) | promote to ready |
| Persona | `pn001` (analyst, validated), `pn002` (platform-engineer, validated) | `pn002` is the actor |
| Category | `cat001` (security), `cat002` (data), `cat003` (infrastructure), `cat004` (observability) | bind `cat001` + `cat003`; `cat002` peripheral, `cat004` light touch |
| ADR | `adr0001` (cat001, ft001 basic-auth binding), `adr0002` (cat002, retention), `adr0003` (cat003, smtplib direct) | `adr0001` binds (auth surface must survive rotation); `adr0002` / `adr0003` not directly relevant |
| Feature | `ft001` (basic-auth), `ft002` (vault-secrets) | `ft002` primary candidate consumer (`secret()` read path needs rotation awareness); `ft001` downstream consumer (owns totp/sessions) |
| Implementation | `im001` (solves us001, analyst dashboard) | unrelated; no overlap with platform-tier rotation |
| Other stories | `us001` (done), `us002` (ready, analyst date filter) | unrelated to rotation |

## Promote decision

`us003.status: draft → ready` applied in-place (same file, same id) —
AC are testable; persona resolves; no missing pieces. Re-emit kept
body identical except the frontmatter flip.

## sp### emitted

New zettel `docs/notes/spec/sp001.md` (next free id; spec dir was
empty).

- Frontmatter: `status: idea`, `created: 2026-05-16`, alias mirrors
  the story.
- H1: `# Spec [[cat001]] [[cat003]] [[board]]` — picked categories
  inline, Index pointer `[[board]]`.
- `## solves` → `[[us003|rotate service credentials without downtime]]`.
- `## problem` populated with the goal + motivation, the AC restated,
  and the full survey output as wikilinks.

### Wikilinks emitted in `## problem`

Every surveyed id that's relevant appears as a wikilink (reference
discipline per `idea-implement` step 10):

- `[[us003]]` — source story (also as the `solves` back-link).
- `[[pn002]]` — persona / actor.
- `[[cat001]]` `[[cat003]]` — primary category bindings (also live in H1).
- `[[cat002]]` `[[cat004]]` — surveyed-but-peripheral, called out as
  not-primary so spec-writing inherits the reasoning.
- `[[ft002]]` — primary candidate consumer (vault-secrets read path).
- `[[ft001]]` — downstream candidate consumer (auth-tier credentials).
- `[[adr0001]]` — binding decision (auth surface).
- `[[adr0002]]` `[[adr0003]]` — surveyed-but-not-binding, named so
  spec-writing knows they were considered and dismissed.
- `[[us001]]` `[[us002]]` — adjacent stories, named as out-of-scope.

The `## problem` section also lists three open questions for
spec-writing (API shape of grace-aware `secret()`, who owns the
5-minute overlap enforcement, which synthetic-check harness owns the
assertion). These are not design decisions — they're flags for the
next stage.

## board.md update

Appended `[[sp001|rotate service credentials without downtime]]` under
`## idea`. Replaced the "Nothing in flight" hub paragraph with a
one-line summary so the board reflects current state.

## Files written

- `docs/notes/us003.md` (modified — status flip only).
- `docs/notes/spec/sp001.md` (new).
- `docs/board.md` (modified — appended under `## idea`).

## Hard gate

Not reached. Story had testable AC, persona resolved, all surveys had
real ids. No `gate_reached.md` written.

## Handoff

Next skill in chain: `infinifu:spec-writing` — picks up `sp001` at
`status: idea` and writes the `## solution` section (chosen approach,
binding ADR references, committed feature consumption, mints an
`im###` if needed).
