# wiki-oxide LSP restore + multi-vault correctness

## Goal

Per-project PKMS (wikilinks, backlinks, search) that works correctly across both surfaces — Neovim editing and Claude Code agents (via the `wiki-oxide` MCP) — with a single indexing platform (markdown-oxide LSP) and reliable multi-vault detection when crossing projects in a monorepo.

## Scope

In scope:
- Restore markdown-oxide LSP as the indexing backend for `wiki_search`, `wiki_tags`, `wiki_references` in `claude/mcp/wiki-oxide/server.py`.
- Make vault detection per-MCP-tool-call instead of one-shot at server boot.
- Pool LSP clients by vault path inside the MCP server, lazy-spawned, self-healing on death.
- Address LSP cache-staleness via `workspace/didChangeWatchedFiles` notifications (and full restart fallback when results look stale).
- Address hover-wedge via timeout + retry-once + pool eviction.
- `wiki_grep` stays as an explicit, orthogonal ripgrep tool (not a replacement for LSP semantics).

Out of scope:
- Inline `#tag` visibility (de-prioritised — "tags are not that important"). LSP-backed `wiki_tags` returns frontmatter/heading symbols only, with a documented limitation note. No markdown-oxide fork or upstream PR for this.
- Cross-vault wikilink resolution. Each vault is self-contained.
- Editor-side (nvim) refactoring beyond verifying `didChangeWatchedFiles` is wired and root_markers stay consistent with MCP detection (`.moxide.toml`, `.obsidian`).
- Mobile / Obsidian-app / web surfaces.

## Background

Predecessor (commit `0451276`) swapped the LSP-backed `wiki_search` and `wiki_tags` in the MCP for ripgrep after observing two LSP bugs:

1. `markdown-oxide` workspaceSymbol cache returned stale notes after file changes (no invalidation on disk events).
2. `workspaceSymbol` only emits `SymbolKind.Constant` entries — inline body `#tag` markers are invisible to LSP.

The marketplace plugin `markdown-oxide-lsp` was then dropped (commits `eee514f`, `a15035d`) on the grounds that nvim already loads `markdown-oxide` directly in `lang-md.lua` and the MCP no longer needed an LSP runtime.

User feedback rejects the architectural shape of that fix: "fix is not that you replace original platform". The original choice of LSP-as-platform was deliberate, and a bug in the platform should be addressed inside the platform, not by silently routing around it with a parallel mechanism (ripgrep) for part of the stack.

Additionally, the MCP currently resolves the vault root once at boot (`VAULT = _detect_vault()` at module import), which means an agent that crosses sub-projects in a monorepo keeps querying the wrong vault. This is the multi-vault correctness bug.

## Architecture

Single platform: `markdown-oxide` LSP indexes notes. Two surfaces consume it:

- **Neovim**: spawns its own `markdown-oxide` per buffer via `lspconfig`; root resolved by `root_markers = { ".moxide.toml", ".obsidian", ".git" }` per buffer. Already working — no change needed beyond verifying `didChangeWatchedFiles.dynamicRegistration = true` and adding a save autocmd to notify the server of changes.
- **wiki-oxide MCP**: a thin LSP client adapter. No ripgrep in the semantic paths. `wiki_grep` stays as a separate, explicitly-named ripgrep tool for generic text search.

Multi-vault is handled by:

- Detecting the vault per tool call (walk-up from the call-supplied `cwd`, or fall back to the MCP server's launch cwd if absent).
- An `LspPool` keyed by vault path, lazy-spawning a `markdown-oxide` subprocess per distinct vault on first hit and reusing it on subsequent calls.

The MCP server's own `os.getcwd()` is fixed at launch time (Claude Code starts the stdio MCP once per session), so each MCP tool accepts an optional `cwd: str | None = None` argument. Agents that change projects pass `cwd` explicitly. Without it, calls fall back to walk-up from server-launch cwd, which is correct for single-project sessions.

```
agent tool call
   │ (optional cwd / vault arg)
   ▼
MCP server
   ├── detect_vault(cwd) ──► vault path | None
   ├── LspPool.get(vault) ──► LspClient (lazy spawn, persistent)
   └── LSP request ────────► response ──► format ──► return

nvim buffer open
   │
   ▼
nvim LSP (root_dir resolved per buffer)
   │
   ▼
markdown-oxide instance (independent of MCP's pool)
```

## Components

1. **`detect_vault(cwd: Path) -> Path | None`** — pure walk-up looking for `.moxide.toml` / `.obsidian`. No `VAULT` module-level singleton.
2. **`LspPool`** — `dict[Path, LspClient]`. `get(vault)` lazy-spawns markdown-oxide per vault; reuses on subsequent calls. Reaps on idle timeout (~10 min) or process death.
3. **`LspClient`** (existing class, hardened):
   - Init handshake per vault root.
   - Send `workspace/didChangeWatchedFiles` before every query (cheap cache nudge).
   - Timeout + retry-once on hang; on second failure evict from pool.
4. **MCP tools** — all gain `cwd: str | None = None`:
   - `wiki_root(cwd)` → vault path.
   - `wiki_list(cwd)` → list `.md` files relative to vault.
   - `wiki_search(query, cwd)` → LSP `workspace/symbol`.
   - `wiki_read(name, cwd)` → filesystem read.
   - `wiki_references(name, cwd)` → LSP `textDocument/references`.
   - `wiki_grep(pattern, cwd)` → ripgrep (kept; named for what it is).
   - `wiki_tags(prefix, cwd)` → LSP `workspace/symbol` filtered by kind. Frontmatter/heading only; inline-tag limitation documented in the tool's docstring.
   - `wiki_preview(name, cwd)` → LSP hover with filesystem fallback.
5. **Ripgrep paths removed** from `wiki_search` and `wiki_tags`. The LSP client class is no longer "retained for future use" — it is the actual implementation.
6. **Neovim (`nvim/plugins/lang-md.lua`)**: confirm `didChangeWatchedFiles.dynamicRegistration = true` (already present), add a `BufWritePost` autocmd to send the notification if LSP doesn't pick it up automatically.
7. **Marketplace**: optionally restore a `markdown-lsp` plugin in `claude/marketplace/` for parity with `svelte-lsp`/`nushell-lsp`/etc. (Optional, low priority — nvim wires the LSP directly.)
8. **Rotz install (`claude/dot.yaml`)**: `markdown-oxide` install already present via `cargo install --locked`. No change.

## Data flow

Cold first call: agent passes `cwd` → walk-up resolves vault → pool miss → spawn markdown-oxide → LSP init → first query.

Warm subsequent calls: same vault → pool hit → `didChangeWatchedFiles` cache nudge → query.

Cross-vault in one session: distinct `cwd` → distinct vault → second pool entry → second LSP process.

No vault found: structured error returned to agent (`{"error": "no vault marker (.moxide.toml/.obsidian) above <cwd>"}`).

Nvim is fully independent — each buffer triggers its own markdown-oxide spawn via LSP root resolution. No IPC between nvim and MCP; markdown-oxide is light enough to run two processes per vault.

## Error handling

| Failure | Response |
|---|---|
| `detect_vault` returns None | `{"error": "no vault marker above <cwd>"}` |
| LSP binary missing | `{"error": "markdown-oxide not installed; run rotz install"}` |
| LSP `initialize` timeout (5s) | Tear down subprocess, retry once; on second fail return error |
| LSP request timeout (3s) | Retry once, then mark pool entry unhealthy and replace |
| LSP process died (broken pipe) | Evict, spawn fresh, retry once |
| Stale workspaceSymbol result (refs a non-existent file) | Force `didChangeWatchedFiles` for that path; retry; if still stale, full LSP restart for that vault |
| `wiki_tags` returns 0 against a non-empty vault | Empty list + `note` field documenting the inline-tag limitation |
| Vault deleted mid-session | Spawn fails → evict + error. Self-heals next call |
| `wiki_read` permission denied | `{"error": "permission denied", "path": "..."}` |

No silent error swallowing; all failures surface to the agent with context. MCP server logs to stderr.

## Testing

**Unit** (pure functions, no subprocess):
- `detect_vault(cwd)` across: inside vault, monorepo sub-vault, no marker, marker at root, nested vaults (deepest wins).
- Tool-arg `cwd` normalization — None falls back to server cwd; explicit override applied.

**Integration** (real LSP subprocess, fixture vaults in `tmp_path`):
- Spawn fresh vault with N notes + wikilinks; assert `wiki_search` returns expected notes via LSP.
- Multi-vault: two fixture vaults in one test run; pool contains two clients; results don't leak.
- Backlinks: A links `[[B]]`; `wiki_references("B")` returns A.
- Wikilink goto: resolve `[[id]]` → file path via LSP definition request.

**Regression** (original bugs):
- Cache staleness: spawn LSP, query, write new note, query again — new note must appear.
- Hover wedge: hammer `wiki_preview` 50×; no hang; self-heal on any timeout.

**Negative**:
- `cwd` outside any vault → error response, no crash.
- LSP binary missing → graceful error.
- Kill LSP subprocess mid-call → next call recovers.

**Manual smoke** post-merge:
- nvim: open note in `acag/docs/wiki/`, `gd` on wikilink hops, `gr` shows backlinks.
- Claude agent: `wiki_search("2605")` in `acag` cwd returns acag stories; same call in `.dotfiles` cwd returns dotfiles wiki entries. No cross-leak.

## Success criteria

1. MCP `wiki_search`, `wiki_tags`, `wiki_references` are LSP-backed end to end. No `rg` invocations in those code paths.
2. `wiki_grep` remains a separate, explicitly named ripgrep tool.
3. Vault detection runs per MCP tool call. An agent that calls `wiki_search` from two different sub-project cwds in one session sees results from each project's own vault, not from whichever vault happened to win at server boot.
4. `LspPool` holds one persistent `markdown-oxide` client per vault; restarted automatically on process death or repeated stale results.
5. Cache-staleness regression test passes (file written between two queries is visible in the second query).
6. Hover-wedge regression test passes (50 sequential preview calls complete without hang).
7. nvim still works as before — multi-vault per-buffer LSP, save triggers `didChangeWatchedFiles` reaching the server.
8. Documented limitation re inline `#tag` markers in `wiki_tags` docstring; no parallel ripgrep stack for tag visibility.

## Open follow-ups (out of scope, file as separate bd issues if pursued)

- Upstream PR to `markdown-oxide` to honor file watchers automatically (would simplify our cache-nudge logic).
- Inline `#tag` indexing — only if/when tags become important. Would require markdown-oxide upstream support or an in-MCP tag indexer that is *explicit* about what it does (not a silent replacement).
