Using story-map skill to forward-lookup path-to-story mapping.

## Stories touching `src/auth/login.ts`

| id | status | title | matched via |
|----|--------|-------|-------------|
| 2605-002 | ready | Reset password via email link | src/auth/login.ts |
| 2605-005 | draft | Two-factor authentication for admins | src/auth/login.ts |

2 stories matched.

**Lookup query:** `grep $'\tsrc/auth/login\.ts$' product/story-map.tsv`

Note: story `2605-005` also has a glob entry `src/auth/2fa/**`, but that pattern only matches paths under `src/auth/2fa/`, so it does *not* cover `src/auth/login.ts`. The match for `2605-005` comes from its explicit `src/auth/login.ts` edge.
