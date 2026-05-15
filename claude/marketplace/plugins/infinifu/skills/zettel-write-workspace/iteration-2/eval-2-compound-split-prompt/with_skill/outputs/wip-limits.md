---
aliases:
  - WIP limits — cap in-flight work to prevent overload
created: 2026-05-15
---
# WIP limits [[product]]

A work-in-progress limit caps how many items can be active in a stage (or system) at one time. The cap is the lever: once it is hit, no new work pulls in until something finishes, which exposes bottlenecks instead of letting them hide as queues. Treat the limit as a design constraint, not a target — set it just tight enough that overload shows up as a visible stall rather than as silent latency and context-switching.

## see also
- [[pull-based-flow]]
- [[on-call-rotation]]

---

Index: [[product]]
