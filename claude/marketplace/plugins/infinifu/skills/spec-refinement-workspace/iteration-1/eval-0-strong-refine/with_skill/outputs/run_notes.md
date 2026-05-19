# sp001 spec-refinement — run notes

## Scope of this run

sp001 was at `status: spec` with `## solution` already populated. The user
brief said: write `## plan` + `## tasks`, finalize `im002.## specs`
back-link, **do not** use bd, **do not** flip status, **do not** touch
`board.md`. So the skill's bd-mediated review loop (`bd show ... | bd
update --design ...`) was applied *as a drafting discipline* against the
sections being authored, not against pre-existing bd tasks. The 8-category
checklist was the rubric used while writing each `### Task N` block; any
draft sub-task that would have tripped an auto-reject row was rewritten
before being committed to disk. No bd ids were attached (that's stage-4
`spec-ready`'s job per akm.md lines 605–631).

## ADR / Feature / Story sanity check (before drafting plan)

- `us003.acceptance_criteria` — three criteria, all testable:
  - "Rotation script can swap secrets while services run" → covered by
    Task 2 (`scripts/rotate_secret.py`) + Task 3 (running reader loop
    during rotation).
  - "Old secret stays valid for 5 minutes after rotation" → covered by
    `OVERLAP_SECONDS = 300` constant + Task 3
    `test_only_new_value_observed_after_window`.
  - "No 5xx during rotation window in synthetic check" → covered by
    Task 3 `test_zero_unhandled_exceptions_during_rotation_window` plus
    the explicit "tiny race window" edge case
    (`test_reader_at_expiry_plus_epsilon_does_not_5xx`).
- `adr0001` (services stay on ft001 basic-auth) — confirmed compatible:
  the plan touches credential *storage/rotation*, not auth path. No new
  auth feature, no SSO. Plan explicitly does not modify auth code.
- `adr0002` (Postgres `report_runs` retention 90d) — confirmed
  unaffected: this spec is vault-side, no schema changes (Task 1 success
  criterion: "No schema change. Vault holds versioned aliases." inherited
  from `im002.data_model`).
- `ft002.api_surface` — declares `secret(name)` as the only read path.
  Plan respects this: `rotate_secret` is introduced as an *internal*
  helper, not re-exported to service packages (Task 1 has a
  `grep -R "rotate_secret" src/services/` zero-hits success criterion).
- `im002` — `approach`, `data_model`, `api_surface`, `components` were
  already aligned with the chosen solution. `## specs` was the only
  unfinished section. Now finalized with `[[sp001|rotate service
  credentials without downtime]]`.

## SRE 8-category pass — outcomes

### 1. Granularity
- Four tasks: 6h, 3h, 5h, 3h. All ≤ 8h, none need subtask breakdown.
- Total ~17h sits comfortably for a single-engineer week. No "epic"
  wrapping needed.

### 2. Implementability (junior engineer test)
- Every task names exact file paths under `files_touched`.
- Every test in `test_plan` has a name and "what bug it catches"
  one-liner — no `test_basic` / `test_it_works`.
- Function signatures specified: `rotate_secret(name, new_value)`,
  `OVERLAP_SECONDS = 300`, `vault._now()`, CLI flags, exit codes.
- Vault alias scheme spelled out (`current:<name>`, `prior:<name>`,
  `prior_expires:<name>`) so a junior doesn't need to invent it.

### 3. Success criteria quality
- Each task has ≥ 5 measurable criteria. Examples of strengthening
  applied during drafting:
  - "Tests pass" → `pytest src/lib/tests/test_vault_rotate.py -q exits 0`
    + named test list.
  - "No bare excepts" → `grep -nE 'except[ ]*:' src/lib/vault.py returns
    0 results` (an actual command).
  - "CLI is safe" → broken out into exit-code table + argv-refusal
    behaviour + name-regex validation.
- Task 3 includes a time-budget criterion (`< 15 seconds`) specifically
  to catch the failure mode where a tired engineer writes a 6-real-minute
  test using `time.sleep`.

### 4. Dependency structure
- Task 1 has no deps (foundation).
- Task 2 depends on Task 1 (needs `rotate_secret`).
- Task 3 depends on Task 1 (needs version-aware `secret()`).
- Task 4 depends on Tasks 1 + 2 (runbook references the helper and CLI).
- No circular deps. Tasks 2 and 3 can run in parallel after Task 1.

### 5. Safety & quality standards
- Plan-level "Anti-patterns" block enumerates: bare except, `time.sleep`
  in production, `assert` for control flow, silent failures, TODOs
  without ticket refs, stub returns, tautological tests. Applied to
  every task.
- Per-task error-handling requirements: typed errors
  (`VaultPermissionError`, `KeyError`, `ValueError`), rollback on
  partial failure (Task 1), explicit CLI exit codes (Task 2).

### 6. Edge cases & failure modes
This is where most of the value landed. Edge cases captured per task:
- **Task 1**: existing read-path cache (most-likely silent-bug source),
  missing prior on first rotation, expired-prior stale-read,
  concurrent rotators, mid-rotation write failure, empty/None/wrong-type
  values, 403 from vault, clock skew shrinking the overlap.
- **Task 2**: secrets on argv (shell-history leak), empty stdin,
  trailing-newline-vs-internal-newline (PEM keys!), SIGINT mid-call.
- **Task 3**: reader at exact flip boundary, the "tiny race window" at
  `prior_expires + 1ns` (literally the 5xx bug the AC was written to
  catch — called out explicitly), reader cache TTL, service that
  imports vault under an alias.
- **Task 4**: stale-checkout runbook execution, concurrent operators,
  rotation during deploy.

### 7. Red flags
- No placeholder text (verified by `grep -E '\[detailed above\]|\[as
  specified\]|\[will be added\]'` returning no hits). The only `TODO`
  match in sp001 is the body of the anti-pattern *defining* what's
  forbidden.
- No vague language. Every "implement X" has a function signature, file
  path, and test list attached.
- Every task has > 3 implementation/test items. None > 8h.
- No "handle later". Cache audit, clock skew, race window, and
  multi-operator coordination are all in-spec.

### 8. Test meaningfulness
Every test specification names the specific bug it catches. Concretely:
- Atomic-flip detection: `test_both_values_observed_during_overlap`
  catches the regression where someone "fixes" the rotation by making
  it instant — which would still pass "zero 5xx" but violate us003's
  5-minute overlap requirement.
- Stale-secret detection: `test_prior_read_after_expiry_raises` catches
  the bug where expired prior is silently served.
- Half-rotation detection: `test_rotate_failure_rolls_back_staging`
  catches mid-rotation crash leaving vault in a broken state.
- Multi-line secret support: `test_cli_strips_only_trailing_newline`
  catches over-eager `.strip()` that would brick PEM-key rotation.
- Bypass detection: `test_all_services_use_secret_only` catches a
  service quietly opening its own vault client and skipping the
  rotation policy.
No tautological tests (no "function returns a value", no "key exists",
no "module imports cleanly").

## Shape of `## plan` and `## tasks`

- `## plan` follows the akm.md schema for a refined spec: file tree,
  conventions, anti-patterns, known limitations.
- `## tasks` uses `### Task N: <name>` per task with H4 properties
  (`#### type`, `#### effort`, `#### depends`, `#### files_touched`,
  `#### success_criteria`, `#### edge_cases`, `#### test_plan`) exactly
  as akm.md specifies. No `#### bd` blocks — stage 4 attaches those.
- Four tasks, all `#### type: task`. None large enough to warrant
  promoting to `feature`.

## im002 back-link
`im002.## specs` was the placeholder `(none yet — spec-refinement
should finalize the back-link)`. Replaced with
`[[sp001|rotate service credentials without downtime]]` matching the
existing alias in `sp001.aliases`. No other section of im002 modified —
status remains `accepted`, narrative untouched.

## What was deliberately NOT done
- `sp001.status` left at `spec` (skill brief said don't flip; stage-4
  `spec-ready` would flip it to `ready`).
- `board.md` not touched (skill brief said don't touch).
- No `bd create` / `bd update` / `bd dep` invocations (skill brief said
  no bd).
- No `## bd` blocks under any task (consistent with stage-3 vs stage-4
  separation in akm.md).
- `.seed_manifest.txt` (untracked seed metadata at sandbox root) was
  unstaged from the captured diff — it's not a product of the skill.

## Final assessment

APPROVE — plan is ready to advance to stage 4 (`spec-ready`), which
will attach bd ids and flip `sp001.status` to `ready` plus move it from
`board.md ## spec` to `board.md ## ready`.
