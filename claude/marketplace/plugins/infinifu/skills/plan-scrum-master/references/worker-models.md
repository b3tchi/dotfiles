# Worker model selection

**Default:** `sonnet`. Cheap-by-default first attempt; the scrum-master will automatically upgrade to `opus` on retry after any failure (rejection, error, blocked). See the "Failure-escalation rule" in SKILL.md → Configuration.

When `worker_model` is set to a specific model, ALL agents (implementers and reviewers) use that model for the **first** attempt. On retry, `sonnet` and `haiku` are upgraded to `opus`; `opus` and `auto` are kept as configured.

When `worker_model = auto`, the scrum master picks per-task based on complexity (no flat default):

| Complexity | Model | Signals |
|------------|-------|---------|
| **High** | `opus` | Multiple files across domains, new architecture, complex logic, integration points, ambiguous requirements |
| **Medium** | `sonnet` | Single-domain changes, clear requirements, moderate logic, well-defined interfaces |
| **Low** | `haiku` | Boilerplate, config changes, simple CRUD, renaming, straightforward tests |

## Rules

- **Reviewers always use the same or higher model than the implementer** — never downgrade for review. A reviewer that is weaker than the implementer cannot catch real flaws.
- **Retry upgrades:** `sonnet` → `opus` on second attempt. `haiku` → `opus`. `opus` stays `opus`. `auto` re-evaluates complexity (and tends to land on `opus` for a task that already failed once).
- Include the chosen model and reasoning in the dispatch summary so the human can override per-task before confirming. Also flag in the summary that retries will upgrade to `opus` so the cost expectation is explicit.
- If the user did not specify `worker_model`, the default is `sonnet` (cheap first, opus on failure). Don't switch silently to `auto` — the user might prefer a flat model for cost predictability and the failure-escalation rule already handles "the cheap model wasn't enough."

## Example dispatch summary line

```
→ bd-XXXX: [title]  (epic bd-AAAA)  model: sonnet  [default — retry will upgrade to opus]
→ bd-ZZZZ: [title]  (epic bd-BBBB)  model: opus    [override — already opus, no upgrade needed]
```

In `auto` mode the reasoning line shows the complexity verdict instead:

```
→ bd-XXXX: [title]  (epic bd-AAAA)  model: sonnet  [auto: medium — single-domain, clear spec]
→ bd-ZZZZ: [title]  (epic bd-BBBB)  model: opus    [auto: high — cross-domain integration]
```
