---
aliases:
  - attach a PDF receipt to a request
status: draft
created: 2026-05-19
---
# Story [[product]]

## role
[[pn001|requestor]]

## want
attach a PDF receipt to a request

## because
the approver has documentation

## acceptance_criteria
- Add a 'Attach receipt' button to the request form
- POST /api/requests/{id}/attachments accepts multipart/form-data and returns 201
- Store the file in S3 under requests/{id}/{uuid}.pdf
- Add an attachments column to the requests table linking to attachment ids

---

Index: [[product]]
