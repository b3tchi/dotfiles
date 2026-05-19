# Product

Acme Internal Platform — small set of internal services serving the
operations analyst, the platform-engineer, and the compliance-officer
personas.

## Stories

### [[pn001|analyst]]

- [[us001|view dashboard of recent reports]] >> [[im001]]
- [[us002|filter reports by date range]]

### [[pn002|platform-engineer]]

- [[us003|rotate service credentials without downtime]]

### [[pn003|compliance-officer]]

- [[us005|quarterly audit-log export]] >> [[im002]]

## Features

- [[ft001|basic-auth (password+TOTP)]]
- [[ft002|vault-secrets]]
- [[ft003|audit-log (append-only deletion ledger)]]

## Architecture Decision Records

### [[cat001|security]]

- [[adr0001|All services authenticate via ft001 basic-auth]]

### [[cat002|data]]

- [[adr0002|Reports written to Postgres, retained 90 days]]

## Categories

- [[cat001|security]] — [[cat002|data]] — [[cat003|infrastructure]] — [[cat004|observability]]

## AKM Reference

- [[akm]] — knowledge model: every zettel type, its schema and life-cycle
