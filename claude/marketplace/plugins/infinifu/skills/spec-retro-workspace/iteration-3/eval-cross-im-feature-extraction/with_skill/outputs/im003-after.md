---
aliases: [im003-reports-smtp-retry]
status: accepted
created: 2026-03-15
---
# Implementation [[cat001]] [[product]]
## solves
[[us003]]
## approach
`reports.sendReport()` wraps the SMTP relay call in
`lib.RetryWithJitter(3, 100*time.Millisecond, send)` — the same
canonical shape `im001` (SSO refresh) and `im002` (Prometheus scrape)
already use. The helper handles transient relay timeouts; the report
service itself stays oblivious to the retry envelope.
## data_model
No new schema. SMTP attempts are not persisted; the helper is in-memory only.
## api_surface
Internal only. `reports.sendReport(report)` returns an error if all 3
attempts fail; otherwise nil. No new external endpoints, no payload changes.
## components
- src/services/reports/smtp.go — story-specific glue: the report-shaped
  closure passed into the retry helper.
- src/lib/retry.go — shared helper (also consumed by im001, im002).
---
Index: [[product]]
