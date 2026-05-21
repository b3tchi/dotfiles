Using story-write skill to capture this as a user story.

Wrote `us015` at `/tmp/sw-iter7-eval6-old/docs/notes/us015.md`.

**Connextra sentence:**
As a requestor, I want a 'Cancel' button on the request detail view, because I sometimes need to cancel after submitting.

**Acceptance criteria** (derived — you didn't specify any, so I derived 4 covering visibility, state transition, terminal-state hiding, and accidental-cancel guard; confirm or revise):

- Cancel button appears on the request detail view for requests in a cancellable state
- clicking Cancel transitions the request to a cancelled state and persists the change
- Cancel button is hidden or disabled once the request is no longer cancellable (already approved, picked, or cancelled)
- cancelling shows a confirmation prompt before the state change to prevent accidental cancellation

**H1 tags:** `[[requestor-flow]] [[product]]` — `requestor-flow` derived from the persona's flow (you didn't specify tags).

**Hub:** `docs/product.md` updated — `us015` appended under `[[pn001|requestor]]`.

**Staging:** sandbox is not a git repo, so the `git add` no-ops; otherwise this would be staged on main per the draft-stage policy.

Anything to revise?
