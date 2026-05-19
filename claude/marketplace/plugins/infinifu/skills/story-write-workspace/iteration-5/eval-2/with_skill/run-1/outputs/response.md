# story-write — eval-2 / with_skill / run-1

## Result

- **Story id:** `us001`
- **Story file:** `docs/notes/us001.md`
- **Persona handling:** no existing personas in workspace → created new persona zettel `pn001.md` for `guest` with status `draft` (minimal name + summary per skill's "If they want a new persona" branch).
- **Hub update:** appended `### [[pn001|guest]]` section under `## Stories` in `docs/product.md` with wikilink to the new story.

## Files created

- `docs/notes/pn001.md` — guest persona (draft)
- `docs/notes/us001.md` — story (draft)

## Files modified

- `docs/product.md` — added persona section + story wikilink

## Connextra sentence

As a `guest`, I want `view the public catalog without signing in`, because `I want to evaluate the products before creating an account`.

## Acceptance criteria (derived)

User did not provide acceptance criteria. Running in auto mode, so 3 baseline criteria were derived covering entry point, success path, and account-only-action boundary:

- catalog landing page is reachable without authentication
- product listings render with name, description, and price for unauthenticated visitors
- attempting an account-only action (e.g. ordering) prompts sign-up rather than failing silently

These should be confirmed or revised by the user.

## H1 tags

`[[guest-flow]] [[catalog]] [[product]]` — `guest-flow` and `catalog` derived from the role and want (user did not explicitly specify tags); `[[product]]` is the required hub link. Tag wikilinks may dangle (no backing zettels yet).
