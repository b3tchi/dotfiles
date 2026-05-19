---
aliases:
  - WIP limits — cap in-flight work to prevent overload
created: 2026-05-15
---
# WIP limits [[product]]

A work-in-progress limit caps how many items a team (or column) may have in flight at once. New work cannot start until existing work moves out, which forces finishing over starting and exposes bottlenecks the moment the cap is hit. The cap is the lever; the visible queue is the diagnostic. Set it too high and overload returns; set it too low and the team starves — tune by observation, not by headcount.

## see also
- [[pull-based-flow]]
- [[on-call-rotation]]

---

Index: [[product]]
