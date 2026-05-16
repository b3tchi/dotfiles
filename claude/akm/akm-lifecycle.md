---
aliases:
  - akm lifecycle
status: draft
created: 2026-05-16
---
# AKM Lifecycle [[product]]

## idea-brainstorming

ok there could be more starts base on idea probably this have to be splited

### us implement
- read: `pn###`, `us###`
- write: `sp###.problem`, `board.md` (reference `## idea`)
### us changed adjust implementation
- read: `pn###`, `us###`, `im###`, `adr###`
- write: `sp###.problem`, `board.md` (reference `## idea`)
### feature add
- read: `ft###`, `us###`, `im###`, `adr###`
- write: `sp###.problem`, `board.md` (reference `## idea`)
### hotfix implementation or feature
- read: `ft###`, `us###`, `im###`, `adr###`
- write: `sp###.problem`, `board.md` (reference `## idea`)

definition of the problem

## spec-writing

ensure solution with adrs and using features

- read: `us###.AC`, `cat###`, `ft###`, `adr###`
- write: `sp###.solution` proposed
- write: `board.md` (reference `## idea` → `## spec`)

## spec-refinement

ensure deliverable workable — SRE 8-category pass

- read: `sp###`, `adr###`, `ft###`
- write: `sp###.plan` (file tree, conventions, anti-patterns)
- write: `sp###.tasks` structured breakdown (H3 per task, H4 per property; no bd ids yet)
- write: `im###.specs` finalize implementation file

## spec-ready

- read: `sp###`
- write: `sp###.tasks` annotate each task `#### bd <id>`
- write: `board.md` (reference `## spec` → `## ready`)
- artifact: beads planned with dependencies

## work-do

- all needed in beads tasks

## work-audit

- all needed in beads tasks including acc

## work-merge

- all needed in beads tasks including acc
- close beads task/bug
- write: `sp###` flip footer `[[board]]` → `[[archive]]`
- write: `board.md` (remove `sp###` reference)
- write: `archive.md` (add `sp###` reference under `## done`)

## spec-retro

- read: diff, `im###`, `ft###`, `adr###`
- write: rewrite `im###`; new `adr###`; update `ft###`; new `us###` drafts
- close beads epic

---

Index: [[product]]
