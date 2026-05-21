---
aliases:
  - cancel button on request detail view
status: draft
created: 2026-05-19
---
# Story [[requestor-flow]] [[product]]

## role
[[pn001|requestor]]

## want
a 'Cancel' button on the request detail view

## because
I sometimes need to cancel after submitting

## acceptance_criteria
- Cancel button appears on the request detail view for requests in a cancellable state
- clicking Cancel transitions the request to a cancelled state and persists the change
- Cancel button is hidden or disabled once the request is no longer cancellable (already approved, picked, or cancelled)
- cancelling shows a confirmation prompt before the state change to prevent accidental cancellation

---

Index: [[product]]
