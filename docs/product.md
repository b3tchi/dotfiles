# Product

Central hub for this PKM. Every typed zettel is reachable from here.

## Stories

### [[pn001|developer]]

- [[us001|mark project as remote so terminals open against the remote host]] >> [[im002]]
- [[us002|register a location as a project and navigate to it easily]] >> [[im001]]
- [[us003|create diagrams]] >> [[im003]]
- [[us004|xrdp access hardened with TLS before exposing it beyond localhost]] (dropped → [[us008]])
- [[us005|the shared i3 config verified live on native linux and proot]]
- [[us006|visualize-note-relations]] >> [[im004]]
- [[us007|work remotely on my development machine — full desktop from another device]] >> [[im005]]
- [[us008|securely access and work on my workstation remotely with full desktop]]
- [[us009|selecting a graph node or diagram element in the preview opens its source in the editor]] (draft)

## Features

- [[ft001|project registry and navigation module]]
- [[ft002|d2-preview-router]]
- [[ft003|i3-config-layering]]
- [[ft004|akm-graph]]
- [[ft005|file-preview-daemon]]

## Architecture Decision Records

### [[cat001|workflow-tooling]]

- [[adr0001|Nushell as primary language for scripts and data manipulation]]
- [[adr0002|When to use bash (vs nushell)]]
- [[adr0003|When to use a compiled helper (Go) instead of nushell]]
- [[adr0007|preview reverse channel routes server-side daemon-to-daemon, not via browser postMessage relay]]

### [[cat002|display-platform]]

- [[adr0004|xrdp + xorgxrdp + llvmpipe as the WSL2 full-desktop remoting stack]]
- [[adr0005|No d3d12 GPU acceleration outside the WSLg-blessed path on WSL2]]
- [[adr0006|preview-d embeds peer daemons via same-origin proxy or cross-origin iframe by frame-header]]

## AKM Reference

- [[akm]] — knowledge model: every zettel type, its schema and life-cycle
