---
aliases:
  - export request history as CSV
status: draft
created: 2026-05-19
---
# Story [[requestor-flow]] [[export]] [[product]]

## role
[[pn001|requestor]]

## want
export my request history as a CSV file

## because
accounting keeps asking for expense reports and screenshotting the dashboard is tedious

## acceptance_criteria
- GET /api/requests/export returns a CSV response
- endpoint is served from the same auth-protected route as the dashboard (unauthenticated requests rejected)
- CSV contains one row per request
- each row includes the request date, status, and total line-item count

---

Index: [[product]]
