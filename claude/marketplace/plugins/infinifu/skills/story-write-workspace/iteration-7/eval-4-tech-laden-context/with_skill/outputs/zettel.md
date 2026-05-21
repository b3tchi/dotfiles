---
aliases:
  - export request history as CSV
status: draft
created: 2026-05-19
---
# Story [[requestor-flow]] [[reporting]] [[product]]

## role
[[pn001|requestor]]

## want
export my request history as a CSV file

## because
accounting keeps asking me for expense reports and screenshotting the dashboard is tedious

## acceptance_criteria
- export produces one row per request in the requestor's history
- each row includes the request date, status, and total line-item count
- only the requestor's own requests appear in the export
- exporting with no request history produces a file with headers and no data rows

---

Index: [[product]]
