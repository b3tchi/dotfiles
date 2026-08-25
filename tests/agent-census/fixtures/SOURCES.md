# Fixture provenance

Every fixture records the command that produced it and the date. The `.txt`
and `.yaml` fixtures carry that as `#` header lines (the runner strips them);
JSON has no comment syntax and a `_meta` key would corrupt the very shape
under test, so the JSON fixtures are documented here instead.

Per [[adr0023]]'s principle, a fixture is a **historical record**. When
`claude agents --all --json` changes shape, add a NEW fixture beside the old
one — never rewrite an existing capture to match current reality, or it
starts asserting something the tool never emitted.

## Captured 2026-08-24

| file | command |
|---|---|
| `agents-personal.json` | `CLAUDE_CONFIG_DIR=$HOME/.claude-personal claude agents --all --json` |
| `agents-work.json` | `CLAUDE_CONFIG_DIR=$HOME/.claude-work claude agents --all --json` |
| `panes.txt` | `tmux list-panes -a -F "#{pane_pid} #{session_group}"` |
| `ps.txt` | `ps -eo pid=,ppid=` |

claude CLI 2.1.x, nushell 0.115.0, tmux on Linux/WSL2.

## Sanitisation

The repository is public. The raw captures carried real project names and
in-flight task descriptions, so paths, tmux `session_group` values, and agent
`name` fields were remapped to neutral labels before the first commit. The raw
captures were never committed.

Everything the tests depend on is preserved **unchanged**:

- record count (7 personal, 6 work) and the `kind` / `state` / `status` spread
- which records carry a `pid` and which do not
- all pids and ppids, so the ancestry walk resolves identically
- one background job whose `cwd` is the repo root while it runs inside
  `.claude/worktrees/<branch>` — the origin-not-worktree property
- one pid-bearing agent whose ancestors reach pid 1 with no pane

Name map: `dotfiles` kept; every other project name → `proj-alpha`…`proj-echo`
or `portfolio`; the capturing account's home directory → `/home/dev`.

The map itself is not written out here on purpose — spelling the real names
would reintroduce exactly what the sanitisation removed, and the
`fixtures/carry-no-real-identifiers` case in the runner fails the suite if
any of them reappears in this directory, this file included.

## The fixture root is not $HOME

Fixtures use the literal root `/home/dev`, declared once in `run-tests.nu` as
`$FIXTURE_ROOT`. Nothing reads the running user's `$HOME`, so the suite passes
under any account — a requirement, since the registry paths and the agent
`cwd` values must line up for attribution cases to mean anything.

## Deliberate hazards

- `projects.yaml` maps `proj-delta` **and** `proj-delta-py` to one identical
  path — two names, one path, so `cwd` alone cannot decide. The real registry
  has this twice.
- `portfolio-old` is a string-prefix sibling of `portfolio`: matching on raw
  string prefix attributes `/…/portfolio-old` to `portfolio`. Matching on path
  components does not.
- `panes-ungrouped.txt` covers an empty `session_group` two ways: a trailing
  space, and no second field at all.
- `panes-crlf.txt` would leave `\r` glued to a project name under a naive split.
- `agents-unknown-state.json` carries `hibernating` and `compacting` — one in
  `state`, one in `status`, neither in the documented bucket table.
