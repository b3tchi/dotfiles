---
aliases:
  - akm lifecycle
status: draft
created: 2026-05-16
---
# AKM Lifecycle [[product]]

## idea-brainstorming (router)

Picks one of four specialized brainstormers based on entry type. Each sub-skill below carries its own AKM hook block in `claude/marketplace/plugins/infinifu/skills/<skill>/SKILL.md`.

### idea-implement
- read: `pn###`, `us###`, `cat###`, `adr###`, `ft###`
- write: `us###` draft → ready, `sp###.Problem`, `board.md` (reference `## Idea`)
### idea-extend
- read: `pn###`, `us###`, `im###`, `cat###`, `adr###`, `ft###`
- write: `sp###.Problem`, `board.md` (reference `## Idea`)
### idea-feature
- read: `ft###`, `us###`, `im###`, `cat###`, `adr###`
- write: `sp###.Problem`, `board.md` (reference `## Idea`)  *(ft### itself minted at spec-writing)*
### idea-hotfix
- read: `ft###`, `us###`, `im###`, `cat###`, `adr###`
- write: `sp###.Problem` (severity / blast radius / rollback / minimal-fix shape), `board.md` (reference `## Idea` with urgency annotation)

definition of the problem (grounded in surveyed categories / ADRs / features — never invented)

## spec-writing

ensure solution with adrs and using features

- read: `us###.AC`, `cat###`, `ft###`, `adr###`
- write: `sp###.Solution` proposed
- write: `board.md` (reference `## Idea` → `## Spec`)

## spec-refinement

ensure deliverable workable — SRE 8-category pass

- read: `sp###`, `adr###`, `ft###`
- write: `sp###.Plan` (file tree, conventions, anti-patterns)
- write: `sp###.Tasks` structured breakdown (H3 per task, H4 per property; no bd ids yet)
- write: `im###.Specs` finalize implementation file

## spec-ready

- read: `sp###`
- write: `sp###.Tasks` annotate each task `#### bd <id>`
- write: `board.md` (reference `## spec` → `## Ready`)
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
- write: `archive.md` (add `sp###` reference under `## Done`)

## spec-retro

- read: diff, `im###`, `ft###`, `adr###`
- write: rewrite `im###`; new `adr###`; update `ft###`; new `us###` drafts
- close beads epic

---

Index: [[product]]
