Using story-find skill to surface stories touching this area + their validation state.

### 2605-005 — Two-factor authentication for admins   (match score: 10)

**As a** admin, **I want** to enable two-factor authentication on my account, **so that** privileged actions are protected against credential theft.

**Tags:** [auth, security]   **Status:** draft

**Acceptance criteria:**
- [ ] TOTP setup flow accessible from account settings
- [ ] Login requires both password and current TOTP code
- [ ] Recovery codes are generated and shown once

Unverified: 0/3 criteria checked (status=draft).

### 2605-002 — Reset password via email link   (match score: 5)

**As a** logged-in user, **I want** to reset my password from a 'forgot password' link, **so that** I don't get locked out of my account.

**Tags:** [auth, account]   **Status:** ready

**Acceptance criteria:**
- [ ] Email is sent within 30 seconds of submitting the form
- [ ] Reset link expires after 1 hour
- [ ] Old password is invalidated immediately on reset

Unverified: 0/3 criteria checked (status=ready).

Coverage for "authentication": 2 matched stories — 0 done, 1 ready, 1 draft. Top match: 2605-005 (score 10).
