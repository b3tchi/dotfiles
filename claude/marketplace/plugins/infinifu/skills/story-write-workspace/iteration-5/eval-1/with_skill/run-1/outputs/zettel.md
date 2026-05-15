---
aliases:
  - mark a request as picked once items are pulled
status: draft
created: 2026-05-14
---
# Story [[picker-flow]] [[fulfillment]] [[product]]

## role
[[pn003|picker]]

## want
mark a request as picked once items are pulled from inventory

## because
that signals the request is ready for handoff

## acceptance_criteria
- picker can transition an approved request to a "picked" state from the fulfillment view
- only requests in the approved state can be marked as picked
- picked timestamp and picker identity are recorded on the request
- requests marked as picked appear in a "ready for handoff" queue

---

Index: [[product]]
