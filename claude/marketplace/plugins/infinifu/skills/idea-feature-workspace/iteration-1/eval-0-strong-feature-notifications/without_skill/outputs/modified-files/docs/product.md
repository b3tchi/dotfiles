# Product

Acme Internal Platform — small set of internal services serving the
operations analyst and the platform-engineer personas.

## Stories

### [[pn001|analyst]]

- [[us001|view dashboard of recent reports]] >> [[im001]]
- [[us002|filter reports by date range]]
- [[us004|get notified when long-running reports finish]]

### [[pn002|platform-engineer]]

- [[us003|rotate service credentials without downtime]]

## Features

- [[ft001|basic-auth (password+TOTP)]]
- [[ft002|vault-secrets]]

## Architecture Decision Records

### [[cat001|security]]

- [[adr0001|All services authenticate via ft001 basic-auth]]

### [[cat002|data]]

- [[adr0002|Reports written to Postgres, retained 90 days]]

### [[cat003|infrastructure]]

- [[adr0003|No external SMTP relay — services use smtplib directly]]

## Categories

- [[cat001|security]] — [[cat002|data]] — [[cat003|infrastructure]] — [[cat004|observability]]

## AKM Reference

- [[akm]] — knowledge model: every zettel type, its schema and life-cycle
