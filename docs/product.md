# Product

Central hub for this PKM. Every typed zettel is reachable from here.

## Stories

### [[pn001|developer]]

- [[us001|mark project as remote so terminals open against the remote host]] >> [[im002]]
- [[us002|register a location as a project and navigate to it easily]] >> [[im001]]
- [[us003|create diagrams]] >> [[im003]]
- [[us004|xrdp access hardened with TLS before exposing it beyond localhost]] (dropped → [[us006]])
- [[us005|the shared i3 config verified live on native linux and proot]]
- [[us006|securely access and work on my workstation remotely with full desktop]]

## Features

- [[ft001|project registry and navigation module]]
- [[ft002|d2-preview-router]]
- [[ft003|i3-config-layering]]

## Architecture Decision Records

### [[cat001|workflow-tooling]]

- [[adr0001|Nushell as primary language for scripts and data manipulation]]
- [[adr0002|When to use bash (vs nushell)]]
- [[adr0003|When to use a compiled helper (Go) instead of nushell]]

### [[cat002|display-platform]]

- [[adr0004|xrdp + xorgxrdp + llvmpipe as the WSL2 full-desktop remoting stack]]
- [[adr0005|No d3d12 GPU acceleration outside the WSLg-blessed path on WSL2]]

## AKM Reference

- [[akm]] — knowledge model: every zettel type, its schema and life-cycle
