Story captured.

- **id:** `2605-001`
- **status:** `draft`
- **tags:** `[auth, account]` *(derived — you didn't specify tags)*
- **storage:** `product/stories.yaml`

> As a **logged-in user**, I want **to reset my password from a 'forgot password' link**, so that **I don't get locked out of my account**.

**Acceptance criteria** *(derived — you didn't specify any, so I generated 4 covering: entry point, success path, expiry, error case)*:

- 'Forgot password' link is visible on the login page and triggers a reset email to the account's registered address
- Reset link opens a password-entry form and successfully updates the account password when submitted with a valid new password
- Reset link expires after a defined window (e.g. 1 hour) and shows an explicit "link expired" message if used afterward
- Submitting the reset form with an invalid or already-used token shows an error and does not change the password

Anything to revise?
