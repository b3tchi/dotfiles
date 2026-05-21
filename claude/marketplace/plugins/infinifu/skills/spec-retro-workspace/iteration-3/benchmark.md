# spec-retro — iteration-3 benchmark

Iteration adds explicit cross-im `## components`/`## approach` scan,
strong-correlation gate (same shape, not just same file), and mandatory
human-verify before any `ft###` mint.

## Summary

| eval | with_skill | old_skill | delta |
|---|---|---|---|
| cross-im-feature-extraction | 9/9 (100%) | 6/9 (67%) | +33pp |

## Behavioral delta

Both versions correctly **refrained from auto-minting** `ft002.md` —
the vertical-over-horizontal default + no-silent-extraction rule was
already in the baseline. The delta is in *how the candidate is
identified*:

- **with_skill:** methodical cross-scan. Lists `im*.md`, reads each
  sibling's `## components` + `## approach`, builds a comparison table
  (same file? same symbol? same call shape?), explicitly classifies
  correlation as Strong/Weak before proposing. Evidence-based.
- **baseline:** prose-spotting. The candidate emerged because `im003`'s
  `## approach` happened to name `auth` and `metrics` as siblings. The
  agent acknowledges: *"If im003.## approach had not named the
  auth/metrics siblings, the candidate would have been missed."*

The seed was deliberately kind to the baseline (prose was forthcoming).
In the wild — where authors often write spec-shaped narratives that
*don't* name siblings — the baseline misses real reuse.

## Cost

with_skill: 62k tokens / 185s. baseline: 56k tokens / 114s.
+12% tokens, +63% wall-clock — the cross-scan reads more files.
Acceptable for a retro pass that runs once per shipped spec.
