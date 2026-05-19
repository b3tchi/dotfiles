## Suggested tags

For draft story:
> **As a** billing admin, **I want** to view monthly subscription invoices, **so that** I can reconcile revenue.

**Suggested:** `[billing, admin]`

- `billing` — matched on "billing", "invoice", "subscription" in want/role (multiple hits, counted double for want). **New tag** — not yet in the existing taxonomy. Proposed because no existing tag covers the billing/invoice/subscription system area, and the draft is squarely in that domain.
- `admin` — matched on "admin" in role (counted double for role/title-equivalent). Existing tag, used by 2 stories (`2605-003`, `2605-005`).

### Taxonomy reuse vs. invention

- `admin` is reused from the existing taxonomy.
- `billing` is **invented** — no other story uses it yet. It is, however, the canonical synonym-table entry for invoice/subscription/payment/plan/charge, so it is the right kebab-case noun for the system area rather than an ad-hoc coinage.

Other tags considered and rejected:
- `reports` — no synonym keyword ("report", "dashboard", "analytic", "chart", "metric") appears in the draft; "reconcile revenue" is the *purpose*, not the artifact, so `reports` would be a stretch.
- `account` — "billing admin" is a role, not an account-management feature; no `account`/`profile`/`my settings` keywords matched.

Confirm or revise. If you want to keep the taxonomy strictly to what already exists, the closest single-tag fallback would be `[admin]` alone, but that loses the billing system area which is the actual subject of the story.
