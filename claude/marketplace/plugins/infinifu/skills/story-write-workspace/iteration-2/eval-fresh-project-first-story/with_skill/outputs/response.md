Using story-create skill to capture this as a user story.

Captured as story **2605-001** in `product/stories.yaml`.

> As a logged-in user, I want to reset my password from a 'forgot password' link, so that I don't get locked out of my account.

**Acceptance criteria:**

- A 'forgot password' link is reachable from the login screen and triggers a reset flow
- Submitting a registered email sends a password reset link to that email; submitting an unregistered email shows the same generic confirmation (no account enumeration)
- The reset link expires after 60 minutes or after a single successful use, whichever comes first; expired/used links show a clear error and offer to request a new one
- Setting a new password via a valid link updates the credential, invalidates any other outstanding reset links for that account, and lets the user sign in with the new password

**Status:** `draft`
**Storage:** `product/stories.yaml`

**Heads-up — derived acceptance criteria:** you didn't specify any acceptance criteria, so I derived 4 baseline ones covering the obvious boundaries: the entry point (link on login screen), the success path (email delivery, with anti-enumeration), expiry/single-use (timeout + reuse), and the completion case (password update + invalidation of other links). None of these came from your message — please confirm or revise. Common things I deliberately did *not* assume: rate-limiting on requests, MFA interaction, password complexity rules, audit logging, and notification to the user that a reset was requested. Let me know if any of those should be in scope and I'll update the story in place.

Anything to revise?
