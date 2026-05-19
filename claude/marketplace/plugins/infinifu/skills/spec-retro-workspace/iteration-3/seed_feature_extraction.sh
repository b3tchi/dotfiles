#!/usr/bin/env bash
# Minimal seed for iteration-3 eval: cross-im feature extraction.
#
# Scenario: 3 implementations all use the same retry helper (src/lib/retry.go).
# im001 (done) — auth service uses retry for SSO token refresh
# im002 (done) — metrics service uses retry for Prometheus scrape
# im003 (just shipped — retro runs on this) — reports service uses retry for SMTP send
#
# Expected behaviour of the new spec-retro: cross-scan detects retry helper
# present in im001 and im002, surfaces a Candidate Feature naming both consumers.
# Old spec-retro: at best raises a speculative candidate, at worst silent.
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

git init -q -b main
git config user.email "eval@local"
git config user.name "eval"

# Codebase — the shared retry helper plus three services consuming it
mkdir -p src/lib src/services/auth src/services/metrics src/services/reports
cat > src/lib/retry.go <<'EOF'
// retry_with_jitter — exponential backoff with jitter for transient errors.
// Consumed by auth (SSO refresh), metrics (Prometheus scrape), reports (SMTP).
package lib

import (
	"math/rand"
	"time"
)

func RetryWithJitter(attempts int, base time.Duration, fn func() error) error {
	var err error
	for i := 0; i < attempts; i++ {
		if err = fn(); err == nil {
			return nil
		}
		jitter := time.Duration(rand.Int63n(int64(base)))
		time.Sleep(base*(1<<i) + jitter)
	}
	return err
}
EOF
cat > src/services/auth/sso.go <<'EOF'
package auth
// SSO token refresh — wraps the call in lib.RetryWithJitter(3, 100ms, refresh)
EOF
cat > src/services/metrics/scrape.go <<'EOF'
package metrics
// Prometheus scrape uses lib.RetryWithJitter for transient 5xx.
EOF
cat > src/services/reports/smtp.go <<'EOF'
package reports
// SMTP send wrapped in lib.RetryWithJitter — added in sp003 (just merged).
EOF

# AKM workspace
mkdir -p docs/notes/spec
cat > docs/product.md <<'EOF'
# Product [[product]]
Internal Acme platform.

## Stories
### [[pn001|engineer]]
- [[us001|harden SSO refresh against transient failures]] >> [[im001]]
- [[us002|stop dropping Prometheus scrapes on transient 5xx]] >> [[im002]]
- [[us003|reliably send analyst report emails]]

## Features
- [[ft001|basic auth]]

## AKM Reference
- [[akm]]
EOF
cat > docs/board.md <<'EOF'
# Board [[product]]

## Idea
## Spec
## Ready
EOF
cat > docs/archive.md <<'EOF'
# Archive [[product]]

## done
- [[sp001|sso retry hardening]]
- [[sp002|prometheus scrape retry]]
- [[sp003|reports smtp retry]]
EOF

cat > docs/notes/akm.md <<'EOF'
---
aliases: [akm]
status: stable
created: 2026-01-01
---
# AKM [[product]]
Im zettel: docs/notes/im###.md with `## approach`, `## components`, `## data_model`, `## api_surface`.
Ft zettel: docs/notes/ft###.md with `## providing`, `## api_surface`, `## components`.
---
Index: [[product]]
EOF

cat > docs/notes/pn001.md <<'EOF'
---
aliases: [engineer]
status: validated
created: 2026-01-01
---
# Persona [[product]]
## name
Platform Engineer
## summary
Owns internal services.
---
Index: [[product]]
EOF

cat > docs/notes/ft001.md <<'EOF'
---
aliases: [basic auth]
status: accepted
created: 2026-01-15
---
# Feature [[cat001]] [[product]]
## providing
SSO + password+TOTP login.
## api_surface
`auth.Login(creds)` returns Session
## components
- src/services/auth/login.go
---
Index: [[product]]
EOF

# Two prior shipped Implementations, both consuming src/lib/retry.go.
cat > docs/notes/im001.md <<'EOF'
---
aliases: [im001-sso-retry]
status: accepted
created: 2026-02-01
---
# Implementation [[cat001]] [[product]]
## solves
[[us001]]
## approach
Wrap SSO refresh in `lib.RetryWithJitter` with 3 attempts, 100ms base.
Exponential backoff with jitter handles the upstream IdP's flapping.
## data_model
No new schema.
## api_surface
Internal only — auth.refreshToken() now retries.
## components
- src/services/auth/sso.go
- src/lib/retry.go
---
Index: [[product]]
EOF

cat > docs/notes/im002.md <<'EOF'
---
aliases: [im002-metrics-retry]
status: accepted
created: 2026-02-20
---
# Implementation [[cat001]] [[product]]
## solves
[[us002]]
## approach
Scrape collector now uses `lib.RetryWithJitter` on transient 5xx from the
Prometheus endpoint. Same retry-with-jitter pattern as the auth refresh.
## data_model
No new schema.
## api_surface
Internal only — scraper.collect() handles transient errors.
## components
- src/services/metrics/scrape.go
- src/lib/retry.go
---
Index: [[product]]
EOF

# The just-shipped Implementation — retro runs on this one
cat > docs/notes/im003.md <<'EOF'
---
aliases: [im003-reports-smtp-retry]
status: accepted
created: 2026-03-15
---
# Implementation [[cat001]] [[product]]
## solves
[[us003]]
## approach
SMTP send is wrapped in `lib.RetryWithJitter` to survive transient relay
failures. Same shape as the auth and metrics services already use —
3 attempts, 100ms base, exponential with jitter.
## data_model
No new schema.
## api_surface
Internal only — reports.sendReport() handles transient SMTP errors.
## components
- src/services/reports/smtp.go
- src/lib/retry.go
---
Index: [[product]]
EOF

# Spec sp003 (the one retro runs on)
cat > docs/notes/spec/sp003.md <<'EOF'
---
aliases: [sp003-reports-smtp-retry]
status: done
created: 2026-03-10
---
# Spec [[product]]
## problem
Report emails fail randomly due to SMTP relay timeouts.
## solution
Wrap reports.sendReport() in retry-with-jitter, matching auth and metrics services.
## plan
- Add SMTP retry wrapper
- Update reports service to use it
## tasks
- bd ix1: implement smtp retry wrapper
---
Index: [[archive]]
EOF

# Cat001 stub
mkdir -p docs/notes
cat > docs/notes/cat001.md <<'EOF'
---
aliases: [services]
status: stable
created: 2026-01-01
---
# Category [[product]]
## name
Internal services
## summary
Bucket for service-related ADRs / features / implementations.
---
Index: [[product]]
EOF

# Commit the seed so retro has git history to diff against
git add .
git commit -qm "seed: 3 services, retry helper, AKM with im001-im003"

# Create a stub "merge" commit so git log <merge-base>..HEAD has something
git commit -q --allow-empty -m "merge sp003: reports smtp retry"

echo "Seeded $SANDBOX with 3 im### (im001 done, im002 done, im003 just shipped). Run spec-retro on sp003."
