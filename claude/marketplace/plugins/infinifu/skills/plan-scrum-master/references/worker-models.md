# Worker model selection

When `worker_model` is set to a specific model, ALL agents (implementers and reviewers) use that model.

When `worker_model = auto`, the scrum master picks per-task based on complexity:

| Complexity | Model | Signals |
|------------|-------|---------|
| **High** | `opus` | Multiple files across domains, new architecture, complex logic, integration points, ambiguous requirements |
| **Medium** | `sonnet` | Single-domain changes, clear requirements, moderate logic, well-defined interfaces |
| **Low** | `haiku` | Boilerplate, config changes, simple CRUD, renaming, straightforward tests |

## Rules

- **Reviewers always use the same or higher model than the implementer** — never downgrade for review. A reviewer that is weaker than the implementer cannot catch real flaws.
- Include the chosen model and reasoning in the dispatch summary so the human can override per-task before confirming.
- If the user did not specify `worker_model`, ask before starting. Do not assume `auto` silently — the human might want a fixed model for cost or determinism.

## Example dispatch summary line

```
→ bd-XXXX: [title]  (epic bd-AAAA)  model: sonnet  [medium — single-domain, clear spec]
→ bd-ZZZZ: [title]  (epic bd-BBBB)  model: opus    [high — cross-domain integration]
```
