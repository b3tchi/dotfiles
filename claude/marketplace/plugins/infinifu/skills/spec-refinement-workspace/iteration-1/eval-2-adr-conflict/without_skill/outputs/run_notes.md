# sp001 spec-refinement — baseline (no skill)

## Issues found in seeded sp001

1. **Implicit ADR supersession.** Body said "[[adr0001]] is implicitly
   superseded by this approach." AKM rules: ADRs are append-only; a new
   ADR must be filed and the old one's `status` flipped to `Superseded`
   with a `## superseded_by` body section. Implicit supersession is not
   a valid transition.
2. **Dangling `[[im002]]` link.** Spec referenced `implements
   [[im002|vault-policy credential rotation for live services]]` but
   no `docs/notes/im002.md` existed. Per AKM, a story should not be
   specced until its Implementation card exists.
3. **Scope explosion vs us003.** Story asks for live rotation with a
   5-minute overlap and zero 5xx. Seeded solution proposed replacing
   the entire credential model with mTLS + a new CA — that is a
   different (and far larger) architectural commitment than what
   us003 requests.
4. **Dismissal of ft002.** Seeded spec said "The CA … doesn't use
   [[ft002]] at all." But `ft002` is `vault-secrets` — the obvious
   building block for credential rotation. No justification given for
   skipping it.
5. **Conflation of two auth axes.** adr0001 is about
   service↔user authentication (password+TOTP via ft001). us003 is
   about rotating service↔dependency credentials (DB URLs, scrape
   tokens). The seeded spec treated these as the same axis and
   proposed superseding the wrong decision.
6. **Missing `## plan` and `## tasks`.** Required by AKM to flip a
   spec from `spec` → `ready`.

## Resolution

- **Reframed solution** to use ft002 (vault-secrets) with a
  dual-secret overlap window. Stays inside us003 scope.
- **adr0001 untouched.** Spec body now states explicitly that
  user-facing auth is out of scope; if user-auth rotation is needed,
  it gets a fresh story + fresh ADR.
- **Created `im002.md`** so the `implements` link resolves and the
  AKM story → implementation → spec chain is intact.
- **Added `## plan` and `## tasks`.** Five tasks with effort, deps,
  files_touched, success_criteria, edge_cases, test_plan. `bd` ids
  intentionally left as placeholders for spec-ready to attach.
- **Flipped status `spec` → `ready`** and moved sp001 under the
  `## ready` heading on `docs/board.md`.
- **Updated `docs/product.md`** to surface `>> [[im002]]` next to
  us003, matching the AKM convention shown on us001.

## Files changed

- New: `docs/notes/im002.md`
- Modified: `docs/notes/spec/sp001.md`, `docs/board.md`,
  `docs/product.md`
- Incidentally staged: `.seed_manifest.txt` (untracked at seed; got
  picked up by `git add -A`)

## Conscious non-changes

- Did **not** mint a new ADR for the rotation contract. The
  dual-secret overlap is an implementation detail of im002 and a
  consumption pattern of ft002; it is not a workspace-level
  architectural choice on the scale of adr0001/adr0002/adr0003.
  If reviewers disagree, a new `adr0004` under `[[cat001]]` can be
  filed cheaply.
- Did **not** modify `ft002`. The dual-version read pattern is
  additive on top of the existing `secret(name)` contract; no
  Feature constraint is being widened in a way that would force a
  `superseded_by` chain.
- Did **not** touch us003. The story is `ready` and its acceptance
  criteria are already testable as written.
