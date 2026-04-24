# Epic: wm-state hardening

## Context

`wm-state restore --rebuild` works for typical layouts (flat + simple nested). Complex 3-level layouts with mixed containers now round-trip, but the imperative i3 rebuild has fragility points that degrade in edge cases. This epic prioritizes the issues by blast radius and tracks fixes so the tool becomes trustworthy at login/logout time.

File: `nushell/actions/wm-state`.

## Priorities

### P0 — critical (data loss / stranded windows)

- **wm-state-F01 — Floating windows in save/restore**
  `build-workspace-layout` walks `nodes` only, ignores `floating_nodes`. Floating windows silently dropped from saved state → lost on restore. Save must capture floating entries (mark `floating: true`) and restore must reapply via `[id=X] floating enable` + optional position.

- **wm-state-F02 — Failure recovery / rollback**
  If any step mid-rebuild errors (IPC failure, i3 bug, user interrupt), matched wids end up stranded in `wm_state_park_<ws>`. No cleanup. Wrap rebuild in `try`; on failure, move every parked wid back to its pre-restore workspace (capture `original_ws` per wid before parking).

### P1 — high (silent wrong result)

- **wm-state-F03 — Sleep-based timing → sync signals**
  100 ms sleeps between IPC calls are heuristic. Slow systems race; fast systems lag. Replace with polling: after each move, re-query `get_tree` until wid appears at expected ws / container, up to a bounded timeout. Or use `i3 subscribe` for structural events.

- **wm-state-F04 — Spawn path race**
  Unmatched entries spawn via `exec <cmd>` then move-by-class-criteria. The new window may not exist when the move fires. Poll for window with matching class (or our slot class/app_id) before issuing move.

- **wm-state-F05 — Cross-session wid handling**
  After logout/login all wids are fresh. `pick-live-match` falls back to class then session, but current order matters and "class only" grabs first-seen — arbitrary. Detect cross-session case (wid from save not in live tree) and prefer session match over class match. For non-session non-tmux apps document the limitation.

### P2 — medium (degrades in specific scenarios)

- **wm-state-F06 — Multiple same-class windows unmatched**
  With N kittys but saved state has M<N slots, matching picks first M by wid/pid/session priority. N-M leftover kittys stay where they were (expected) but matching order of M is arbitrary when pid/wid both dead. Add a path-similarity tiebreak (prefer window whose current container most resembles saved position).

- **wm-state-F07 — Dry-run side-effects in spawn path**
  `spawn-for` calls `tmux-start` which creates tmux sessions as a side effect. Dry-run should be read-only. Move `tmux-start` call into the live-only branch of restore, pre-compute targets or skip on dry-run.

- **wm-state-F08 — `workspace_layout` config hardening**
  Fixed for `workspace_layout tabbed` by placing root anchor inside the top-level con. Untested for `stacking` and `default` values. Test matrix: run rebuild with each `workspace_layout` setting and verify structure.

### P3 — low (cosmetic / self-healing)

- **wm-state-F09 — Workspace's own outer layout**
  append_layout adds a child con with saved layout inside workspace, but workspace itself retains whatever outer layout it had (`splitv`, `tabbed`, …). Cosmetic when workspace has single child, but breaks the "already matches, skip" equality check. Apply `[workspace=X] layout <saved-root-type>` after rebuild (test whether i3 accepts it on workspace root).

- **wm-state-F10 — Structural-equality skip imprecision**
  `current_layout == saved_layout` is exact record compare. Workspaces visually identical but with extra single-child wrappers don't skip. Canonicalize both sides (collapse single-child container chains) before compare.

- **wm-state-F11 — Park workspace cleanup**
  `wm_state_park_<ws>` persists if rebuild skips kill step or crashes. After successful rebuild, explicitly remove the park ws (move any leftover windows back to original ws, then empty ws auto-removes).

- **wm-state-F12 — Multi-output park placement**
  Park ws created on arbitrary output. If user is on laptop and park lands on external monitor, cosmetic flicker. Explicitly pin park ws to same output as target ws via `move workspace to output <output>`.

- **wm-state-F13 — Nested same-type sibling collision**
  `{splith: {splith: ..., splith: ...}}` cannot be encoded (YAML key collision). Current uniquify appends `-2`, `-3` on save; restore strips suffix. Works for shallow cases. Add test case with adjacent same-type nesting (rare but legal in i3 via deep splits).

- **wm-state-F14 — Empty container cleanup after rebuild**
  If anchor container's leaves fail to move and only the anchor is present, killing anchor collapses the wrapper. Usually fine — i3 auto-flattens. Audit to confirm no lingering empty containers after failure modes.

## Verification

Each P0/P1 task must include a repeatable test:
- Craft a saved yaml with the specific scenario
- Temporarily replace `~/.cache/sway-state.yaml`
- Run `wm-state restore --rebuild --dry-run` and live
- Assert resulting tree matches saved via `build-workspace-layout`

Cache backup pattern (prevents losing real state during tests):
```
cp ~/.cache/sway-state.yaml /tmp/wm-state-backup.yaml
# … test …
cp /tmp/wm-state-backup.yaml ~/.cache/sway-state.yaml
```

## Out of scope

- Canonical `append_layout` + kill-and-respawn flow — documented upstream (i3 layout-saving), not pursued because we want to preserve live window state.
- Multi-display layout (per-output structure) — current save/restore per-workspace ignores output.
- Sway-specific testing — code is WM-agnostic but only tested under i3. Sway path likely has quirks (different default workspace_layout, different `app_id` vs `class` swallow, different back_and_forth semantics).
