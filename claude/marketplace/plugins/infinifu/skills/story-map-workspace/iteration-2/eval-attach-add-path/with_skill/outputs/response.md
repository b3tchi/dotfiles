Using story-map skill to attach path-to-story mapping.

## Attach: `src/payments/checkout.ts` → `2605-001`

- **Story validated**: `2605-001` exists in `product/stories.yaml` ("Export query results as CSV", status: done).
- **Existence check**: `src/payments/checkout.ts` does **not** exist in the working tree. Proceeded under auto mode and noting the warning.
- **Already indexed?** No — the edge `2605-001 ↔ src/payments/checkout.ts` was not present.
- **Action**: Appended the line `2605-001\tsrc/payments/checkout.ts` to `product/story-map.tsv`, then re-sorted by id then path.

## New state for 2605-001 — Export query results as CSV

**Paths:**
- `src/components/ExportButton.svelte`
- `src/export/csv.test.ts`
- `src/export/csv.ts`
- `src/payments/checkout.ts`

4 paths indexed.

## Warnings

- `src/payments/checkout.ts` is **not present in the working tree**. The map now references a non-existent path. Either create the file, or remove the mapping with `remove src/payments/checkout.ts from 2605-001` if this was a mistake.
- Note: this attachment looks topically unusual — `2605-001` is a CSV export story, while `src/payments/checkout.ts` sounds like a payments concern. Worth double-checking the intent.
