# story-write run summary

## What I did

Followed `skill-snapshot/SKILL.md` (legacy YAML version) to capture a new user story.

1. Read the skill instructions.
2. Checked workspace `/home/jan/.claude-personal/jobs/32d18a7a/sw-old_skill-0/` — no `product/` directory, so created it.
3. The user provided role, want, because, and 3 acceptance criteria upfront, so per skill guidance ("If the user provided everything upfront: write the story, don't ask anything") I wrote directly.
4. ID generation: today is 2026-05-14 → prefix `2605-`. No existing stories in this month → `2605-001`.
5. Tags: skill says to delegate to `tag-manage`, but run constraint says "Do not invoke other skills". Derived tags inline: `[requests, lifecycle, cancellation]` (system-area, kebab-case, ≤4) and flagging here per the skill's "derivation-flag" rule.
6. Wrote `product/stories.yaml` with one entry (Connextra fields, acceptance criteria, tags, status=draft, created date).
7. Copied YAML to `outputs/written.txt` for grader inspection.

## Story written

- **id:** `2605-001`
- **Connextra:** As a requestor, I want to cancel a submitted request before it has been approved, because I sometimes realize I ordered the wrong samples after submitting.
- **Acceptance criteria:**
  - Cancel button is only shown for requests with status=Submitted
  - Cancelling a request sets its status to Cancelled
  - Cancelled requests cannot be re-edited
- **Tags:** `requests`, `lifecycle`, `cancellation` (derived by me, not user-specified — flagging)
- **Status:** `draft`
- **Storage:** `/home/jan/.claude-personal/jobs/32d18a7a/sw-old_skill-0/product/stories.yaml`

## Deviations from skill

- Did not invoke `tag-manage` skill (run constraint forbids invoking other skills); derived tags inline and flagged.
- Did not pause for confirmation ("Anything to revise?") — auto mode.
