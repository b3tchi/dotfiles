---
aliases: [im003-reports-smtp-retry]
status: accepted
created: 2026-03-15
---
# Implementation [[cat001]] [[product]]
## solves
[[us003]]
## approach
`reports.sendReport` wraps the SMTP relay call in `lib.RetryWithJitter`
(3 attempts, 100ms base, exponential backoff with jitter) to survive
transient relay failures. Mirrors the retry shape already in use by the
auth SSO refresh ([[im001]]) and the Prometheus scraper ([[im002]]).
## data_model
No new schema.
## api_surface
Internal only — `reports.sendReport()` swallows transient SMTP errors
and surfaces only the terminal failure to its caller.
## components
- src/services/reports/smtp.go — call site
- src/lib/retry.go — shared `RetryWithJitter` helper (also consumed by [[im001]], [[im002]])
---
Index: [[product]]
