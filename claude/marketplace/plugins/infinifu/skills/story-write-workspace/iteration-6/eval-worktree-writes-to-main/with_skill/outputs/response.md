# story-write run report

## Workflow

1. Resolved `AKM_ROOT` via `akm-root` from cwd `/tmp/sw-iter6-new/feat` (feature branch) → `/tmp/sw-iter6-new/main`.
2. Verified `$AKM_ROOT/docs/product.md` exists (AKM workspace initialized).
3. Scanned `$AKM_ROOT/docs/notes/us*.md` — max existing id is `us014`, so next id is `us015`.
4. Picked persona `pn001` (alias `requestor`) per the prompt and matched its frontmatter alias.
5. Wrote zettel `$AKM_ROOT/docs/notes/us015.md` per the AKM Story schema.
6. Updated hub `$AKM_ROOT/docs/product.md` — appended `[[us015|...]]` under the existing `### [[pn001|requestor]]` section.
7. Staged on main only: `git -C "$AKM_ROOT" add docs/notes/us015.md docs/product.md`. Did NOT commit (draft artifact policy).
8. Confirmed feat worktree is untouched — no `docs/` writes leaked to `/tmp/sw-iter6-new/feat`.

## Resolved paths

- AKM root: `/tmp/sw-iter6-new/main`
- Zettel: `/tmp/sw-iter6-new/main/docs/notes/us015.md`
- Hub: `/tmp/sw-iter6-new/main/docs/product.md`
- cwd at invocation: `/tmp/sw-iter6-new/feat` (feature worktree, branch `feat`)

## Staging state on main

```
A  docs/notes/us015.md
M  docs/product.md
```

No commit made. The next lifecycle skill (`spec-writing`, on `draft → ready`) will commit accumulated AKM changes.

## User-facing response

> Using story-write skill to capture this as a user story.
>
> Wrote **us015** to `/tmp/sw-iter6-new/main/docs/notes/us015.md` (AKM root resolved via `akm-root` — file landed on `main`, not the `feat` worktree).
>
> **Story:** As a requestor, I want to clone a previous request as a starting point for a new one, because most of my orders look almost identical to past ones.
>
> **Acceptance criteria:**
> - clone button visible on closed requests
> - clone copies line items but leaves notes blank
> - cloned request starts in Draft status
>
> **H1 tags:** `[[requestor-flow]] [[product]]` — `requestor-flow` reused from existing stories (us013, us014). I did not invent new tags.
>
> **Hub updated:** appended under `### [[pn001|requestor]]` in `docs/product.md`.
>
> **Staged on main**, not committed — story is `draft`; commit happens when `spec-writing` flips it to `ready`.
>
> Anything to revise?
