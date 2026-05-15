Using story-create skill to capture this as a user story.

Story captured.

- **id:** `2605-001`
- **Connextra:** As a logged-in user, I want to reset my password from a 'forgot password' link, so that I don't get locked out of my account.
- **Acceptance criteria:**
  - 'Forgot password' link is visible on the login screen and initiates the reset flow
  - Submitting a registered email address sends a password reset email containing a unique reset link
  - Clicking the reset link opens a form that accepts a new password and confirms the change on submit
  - Reset link expires after a single successful use or after 24 hours, whichever comes first
- **Status:** `draft`
- **Saved to:** `product/stories.yaml`

Note: you didn't specify acceptance criteria, so I derived four covering the entry point, email delivery, reset form, and link expiry/security. Anything to revise?
