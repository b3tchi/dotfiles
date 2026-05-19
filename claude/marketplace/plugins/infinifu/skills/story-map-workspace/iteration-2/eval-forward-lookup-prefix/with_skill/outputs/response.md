Using story-map skill to forward path-to-story mapping.

## Stories touching `src/auth/`

| id | status | title | matched via |
|----|--------|-------|-------------|
| 2605-002 | ready | Reset password via email link | src/auth/login.ts, src/auth/password-reset.ts |
| 2605-005 | draft | Two-factor authentication for admins | src/auth/2fa/**, src/auth/login.ts |

2 stories matched.

---

**Lookup command used (prefix forward lookup):**

```bash
grep $'\t'"src/auth/" product/story-map.tsv | cut -f1 | sort -u
```
