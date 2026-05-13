# wiki-oxide LSP Restore + Multi-Vault Implementation Plan

> **For Claude:** Use infinifu:plan-scrum-master (automated) or infinifu:plan-supervised (user reviews each batch) to implement this plan.

**Epic:** `dotfiles-wq0`
**Tasks:** `dotfiles-wq0.1` … `dotfiles-wq0.N` (created by `spec-ready` from the Task sections below)

**Goal:** Restore `markdown-oxide` LSP as the single indexing platform for the `wiki-oxide` MCP (no ripgrep in semantic search / tags / references paths), and fix per-MCP-tool-call vault detection so an agent crossing sub-projects in a monorepo always queries the correct `.moxide.toml`-marked vault.

**Architecture:** The MCP server (`claude/mcp/wiki-oxide/server.py`) becomes a thin LSP-client adapter. Every tool gains an optional `cwd: str | None = None` argument and walks up from that `cwd` to find the nearest vault marker (`.moxide.toml`, `.obsidian`). An `LspPool` keyed by vault path lazy-spawns one persistent `markdown-oxide` subprocess per vault, with timeout/retry/self-heal on death. `wiki_grep` stays as an explicit, separately-named ripgrep tool — it does not back the LSP-semantic tools. Neovim already wires `markdown-oxide` via `lspconfig` per buffer; the spec verifies that path and adds a save-time `didChangeWatchedFiles` autocmd if the server doesn't pick it up automatically.

**Tech Stack:** Python 3.10+, `mcp[cli]` FastMCP server, `markdown-oxide` LSP (Rust binary, installed via `cargo install --locked` in `claude/dot.yaml`), `pytest` for tests, Neovim `lspconfig` for the editor surface.

---

## Conventions

- All paths absolute. The MCP server lives at `claude/mcp/wiki-oxide/server.py`. Tests live in `claude/mcp/wiki-oxide/tests/` (new directory created by Task 1).
- Tests run with `uv run --with pytest pytest claude/mcp/wiki-oxide/tests/ -v` from the repo root. The MCP itself is launched via the `uv run --quiet --script` shebang already present in `server.py`.
- The `markdown-oxide` binary must be on `$PATH` for LSP-backed code paths and tests; tests that need it use `pytest.importorskip`-style `shutil.which("markdown-oxide")` skips so the suite still runs on hosts without it.
- Commit style follows recent project history: Conventional Commits, e.g. `refactor(claude/mcp/wiki-oxide): per-call vault detection`, `feat(claude/mcp/wiki-oxide): restore LSP-backed wiki_search`. Code/commit messages stay in normal English regardless of caveman mode.
- Each Task is one bd issue and is committed independently. Pre-commit hooks must pass; no `--no-verify`.
- `wiki_grep` is the **only** ripgrep tool that remains in the MCP. It is explicitly named for what it does and is orthogonal to PKMS semantics. Do not call out to `rg` from any other tool.

## Anti-patterns

- Do **not** retain the `VAULT` module-level singleton (`server.py:91`) under any name. Every tool resolves its vault from its own `cwd` argument.
- Do **not** silently swallow LSP errors. Every failure path returns a structured `{"error": "...", ...}` dict and logs to stderr.
- Do **not** reintroduce ripgrep into `wiki_search`, `wiki_tags`, or `wiki_references`. They are LSP-backed. If LSP cannot answer (e.g. inline `#tag` markers), document the limitation in the docstring; do not paper over it with a parallel mechanism.
- Do **not** spawn a new `markdown-oxide` subprocess for every tool call. Spawn once per vault and reuse via the pool.
- Do **not** add behaviour the task does not require — no new MCP tools, no new env vars beyond the existing `WIKI_ROOT` fallback, no new config knobs.
- Do **not** commit a `TODO` without a follow-up bd issue referenced in the commit body.

## Known limitations (documented, not fixed in this epic)

1. **Inline `#tag` markers** are not indexed by `markdown-oxide`'s `workspace/symbol` (only frontmatter and heading-level tags surface as `SymbolKind.Constant`). `wiki_tags` will therefore return a smaller set than the previous ripgrep implementation. This is accepted ("tags are not that important"). The docstring records the limitation. A follow-up bd issue may be filed to pursue an upstream `markdown-oxide` fix, but it is not part of this epic.
2. **Cross-vault links** (e.g. a note in `projects/a/docs/wiki/` linking to one in `projects/b/docs/wiki/`) are not supported. Each vault is self-contained.

## File tree

```
claude/mcp/wiki-oxide/
├── server.py                       (heavy refactor — see tasks below)
└── tests/                          (new)
    ├── __init__.py
    ├── conftest.py                 (fixture vault + LSP availability skip)
    ├── test_detect_vault.py
    ├── test_lsp_pool.py
    ├── test_tool_cwd_arg.py
    ├── test_wiki_search.py
    ├── test_wiki_references.py
    ├── test_wiki_tags.py
    ├── test_multi_vault.py
    └── test_regression.py          (cache staleness + hover wedge)

nvim/plugins/lang-md.lua            (small additive change — save-time notify)

claude/marketplace/plugins/markdown-lsp/   (optional — restore plugin)
```

---

## Task 1: Test scaffolding — pytest setup and fixture vault helpers

Stand up the test harness first so every subsequent task is TDD.

**Files:**
- Create: `claude/mcp/wiki-oxide/tests/__init__.py` (empty)
- Create: `claude/mcp/wiki-oxide/tests/conftest.py`

**Step 1: Create the empty `__init__.py`**

```bash
touch /home/jan/.dotfiles/claude/mcp/wiki-oxide/tests/__init__.py
```

**Step 2: Write `conftest.py`**

```python
"""Shared pytest fixtures for wiki-oxide MCP tests."""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

import pytest

# Make server.py importable as a module without running mcp.run().
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


@pytest.fixture
def require_markdown_oxide():
    """Skip the test if markdown-oxide is not on PATH."""
    if not shutil.which("markdown-oxide"):
        pytest.skip("markdown-oxide LSP binary not installed")


@pytest.fixture
def fixture_vault(tmp_path: Path) -> Path:
    """Create a small marker-tagged vault with a few interlinked notes."""
    vault = tmp_path / "docs" / "wiki"
    vault.mkdir(parents=True)
    (vault / ".moxide.toml").write_text("")
    (vault / "alpha.md").write_text(
        "# Alpha\n\nRefers to [[beta]].\n\n#topic-a\n"
    )
    (vault / "beta.md").write_text(
        "# Beta\n\nBacklink target for alpha.\n\n#topic-b\n"
    )
    (vault / "gamma.md").write_text(
        "# Gamma\n\nNo links here.\n"
    )
    return vault


@pytest.fixture
def two_vaults(tmp_path: Path) -> tuple[Path, Path]:
    """Two independent vaults in one project tree — for multi-vault tests."""
    repo = tmp_path / "repo"
    a = repo / "projects" / "a" / "docs" / "wiki"
    b = repo / "projects" / "b" / "docs" / "wiki"
    for v, label in ((a, "a"), (b, "b")):
        v.mkdir(parents=True)
        (v / ".moxide.toml").write_text("")
        (v / f"note-{label}.md").write_text(f"# Note {label}\n")
    return a, b
```

**Step 3: Run the empty test discovery to confirm pytest picks the dir up**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/ -v
```

Expected: `no tests ran`. No collection errors.

**Step 4: Commit**

```bash
git add claude/mcp/wiki-oxide/tests/
git commit -m "test(claude/mcp/wiki-oxide): scaffold pytest dir with fixture vault helpers"
```

---

## Task 2: Pure vault-detect refactor — remove module-level `VAULT`

Make `_detect_vault` take a `cwd` argument; delete the module-level singleton. All existing tool bodies are updated mechanically: each gains a single-line `vault = _detect_vault(Path.cwd())` shim and replaces every `VAULT` read with `vault`. No public-API change yet — that comes in Task 4.

**Files:**
- Test: `claude/mcp/wiki-oxide/tests/test_detect_vault.py` (new)
- Modify: `claude/mcp/wiki-oxide/server.py` (delete line 91, change signature of `_detect_vault`, drop `_VAULT_FALLBACK`, update every read of `VAULT`)

**Step 1: Write the failing test**

```python
"""Unit tests for vault detection — pure function, no LSP needed."""
from pathlib import Path

import pytest

from server import _detect_vault


def test_inside_vault(fixture_vault: Path):
    assert _detect_vault(fixture_vault) == fixture_vault.resolve()


def test_deep_inside_vault(fixture_vault: Path):
    sub = fixture_vault / "sub"
    sub.mkdir()
    (sub / "note.md").write_text("# note\n")
    assert _detect_vault(sub) == fixture_vault.resolve()


def test_outside_any_vault(tmp_path: Path):
    assert _detect_vault(tmp_path) is None


def test_monorepo_sub_vault_wins(two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    assert _detect_vault(a) == a.resolve()
    assert _detect_vault(b) == b.resolve()


def test_nested_vaults_deepest_wins(tmp_path: Path):
    outer = tmp_path / "outer"
    inner = outer / "inner"
    inner.mkdir(parents=True)
    (outer / ".moxide.toml").write_text("")
    (inner / ".moxide.toml").write_text("")
    assert _detect_vault(inner) == inner.resolve()
```

**Step 2: Run to confirm failure**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_detect_vault.py -v
```

Expected: collection errors or failures because the current `_detect_vault()` takes no arguments.

**Step 3: Refactor `server.py`**

- Change `_detect_vault` (line 80) to `def _detect_vault(cwd: Path) -> Path | None:`. Drop the internal `Path.cwd()` call. Return `None` (not `_VAULT_FALLBACK`) when no marker is found. Keep the `WIKI_ROOT` env override but only when the env-provided path exists; return `None` otherwise.
- Delete `_VAULT_FALLBACK` (line 47) and the module-level `VAULT = _detect_vault()` (line 91).
- For each occurrence of `VAULT` in tool bodies (`wiki_search`, `wiki_tags`, `wiki_grep`, `wiki_list`, `wiki_root`, `_resolve_note`, `wiki_read`, `wiki_preview`, `wiki_references`): prepend `vault = _detect_vault(Path.cwd())` and rename `VAULT` → `vault` in the body. If `vault is None`, return the error shape appropriate to the tool's return type (`{"error": "..."}` for dict-returning, `[{"error": "..."}]` for list-of-dict, `[f"error: ..."]` for list-of-str, `f"error: ..."` for `wiki_root`).
- Update the `__main__` guard at line 535: call `_detect_vault(Path.cwd())` once and, if it's `None`, print a clearer error mentioning `.moxide.toml` / `.obsidian` markers and `sys.exit(1)`.
- Update `get_client()` (line 217) to take `vault: Path` and pass it to `LspClient(vault)`. The pool work in Task 3 replaces this entirely; the shim here keeps the file importable.

**Step 4: Run the tests, confirm they pass**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_detect_vault.py -v
```

Expected: all five tests PASS.

**Step 5: Commit**

```bash
git add claude/mcp/wiki-oxide/server.py claude/mcp/wiki-oxide/tests/test_detect_vault.py
git commit -m "refactor(claude/mcp/wiki-oxide): per-call vault detection, drop VAULT singleton"
```

---

## Task 3: Introduce `LspPool` — one persistent LSP client per vault

Replace the `_client` / `get_client()` pair with a class that maps vault path → `LspClient`. Lazy spawn on miss; reap on process death.

**Files:**
- Test: `claude/mcp/wiki-oxide/tests/test_lsp_pool.py` (new)
- Modify: `claude/mcp/wiki-oxide/server.py` (delete `_client`, `_client_lock`, `get_client` at lines 213-222; add `LspPool` class and module-level `_pool` instance)

**Step 1: Write the failing test**

```python
"""Tests for the LspPool — one persistent LSP client per vault path."""
from pathlib import Path

import pytest

from server import LspPool


def test_pool_miss_then_hit(require_markdown_oxide, fixture_vault: Path):
    pool = LspPool()
    c1 = pool.get(fixture_vault)
    c2 = pool.get(fixture_vault)
    assert c1 is c2, "same vault must return same client"


def test_pool_two_vaults_two_clients(require_markdown_oxide, two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    pool = LspPool()
    ca = pool.get(a)
    cb = pool.get(b)
    assert ca is not cb
    assert ca.cwd == a.resolve()
    assert cb.cwd == b.resolve()


def test_pool_respawns_after_process_death(require_markdown_oxide, fixture_vault: Path):
    pool = LspPool()
    c1 = pool.get(fixture_vault)
    assert c1.proc is not None
    c1.proc.terminate()
    c1.proc.wait(timeout=5)
    c2 = pool.get(fixture_vault)
    assert c2 is not c1, "dead client must be evicted and replaced"
```

**Step 2: Run to confirm failure**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_lsp_pool.py -v
```

Expected: ImportError on `LspPool`.

**Step 3: Implement `LspPool`**

Delete lines 213-222 of `server.py` (`_client`, `_client_lock`, `get_client`). Replace with:

```python
class LspPool:
    """Map of vault-path → LspClient. Lazy spawn, self-heal on process death."""

    def __init__(self):
        self._clients: dict[Path, LspClient] = {}
        self._lock = threading.Lock()

    def get(self, vault: Path) -> LspClient:
        vault = vault.resolve()
        with self._lock:
            client = self._clients.get(vault)
            if client is not None and client.proc is not None and client.proc.poll() is None:
                return client
            if client is not None:
                self._clients.pop(vault, None)
            client = LspClient(vault)
            self._clients[vault] = client
            return client


_pool = LspPool()
```

If anything in the file still references `get_client(vault)`, replace with `_pool.get(vault)`.

**Step 4: Run the tests, confirm they pass**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_lsp_pool.py -v
```

Expected: 3 tests PASS (or SKIP if `markdown-oxide` is not installed).

**Step 5: Commit**

```bash
git add claude/mcp/wiki-oxide/server.py claude/mcp/wiki-oxide/tests/test_lsp_pool.py
git commit -m "feat(claude/mcp/wiki-oxide): LspPool — one persistent LSP client per vault"
```

---

## Task 4: Add `cwd` arg to all MCP tools

Every `@mcp.tool()` accepts an optional `cwd: str | None = None`. Replace the in-body `_detect_vault(Path.cwd())` shim from Task 2 with a single helper `_resolve_call_vault(cwd)`.

**Files:**
- Test: `claude/mcp/wiki-oxide/tests/test_tool_cwd_arg.py` (new)
- Modify: `claude/mcp/wiki-oxide/server.py` — every `@mcp.tool()` signature; add helper.

**Step 1: Write the failing test**

```python
"""Each MCP tool must accept an optional cwd argument and route to that vault."""
from pathlib import Path

import pytest

from server import wiki_list, wiki_root


def test_wiki_root_with_explicit_cwd(fixture_vault: Path):
    assert wiki_root(cwd=str(fixture_vault)) == str(fixture_vault.resolve())


def test_wiki_root_picks_correct_vault_per_call(two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    assert wiki_root(cwd=str(a)) == str(a.resolve())
    assert wiki_root(cwd=str(b)) == str(b.resolve())


def test_wiki_list_with_explicit_cwd(fixture_vault: Path):
    files = wiki_list(cwd=str(fixture_vault))
    assert "alpha.md" in files
    assert "beta.md" in files


def test_wiki_root_no_marker_returns_error(tmp_path: Path):
    result = wiki_root(cwd=str(tmp_path))
    assert isinstance(result, str)
    assert result.startswith("error:")
```

**Step 2: Run to confirm failure**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_tool_cwd_arg.py -v
```

Expected: failures because tools don't accept `cwd`.

**Step 3: Add `_resolve_call_vault` and update every tool signature**

Add helper near top of `server.py` (after `_detect_vault`):

```python
def _resolve_call_vault(cwd: str | None) -> Path | None:
    """Resolve the vault for a single MCP tool call."""
    start = Path(cwd).resolve() if cwd else Path.cwd()
    return _detect_vault(start)
```

For each tool, add `cwd: str | None = None` to the signature and replace the in-body shim with `vault = _resolve_call_vault(cwd)`. `_resolve_note` now takes `vault: Path` as its first positional arg.

**Step 4: Run the tests, confirm they pass**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_tool_cwd_arg.py -v
```

Expected: all four tests PASS.

**Step 5: Commit**

```bash
git add claude/mcp/wiki-oxide/server.py claude/mcp/wiki-oxide/tests/test_tool_cwd_arg.py
git commit -m "feat(claude/mcp/wiki-oxide): tools accept cwd arg, route each call to its own vault"
```

---

## Task 5: Restore LSP-backed `wiki_search`

Replace the ripgrep filename + heading + tag fan-out with a single `workspace/symbol` request via the pool.

**Files:**
- Test: `claude/mcp/wiki-oxide/tests/test_wiki_search.py` (new)
- Modify: `claude/mcp/wiki-oxide/server.py` — body of `wiki_search` (current lines 229-312)

**Step 1: Write the failing test**

```python
"""wiki_search must be LSP-backed and per-call-vault aware."""
from pathlib import Path

import pytest

from server import wiki_search


def test_wiki_search_finds_note_by_name(require_markdown_oxide, fixture_vault: Path):
    results = wiki_search("alpha", cwd=str(fixture_vault))
    assert any(r.get("name", "").lower().startswith("alpha") for r in results)


def test_wiki_search_finds_note_by_heading(require_markdown_oxide, fixture_vault: Path):
    results = wiki_search("Beta", cwd=str(fixture_vault))
    assert any("beta" in r.get("name", "").lower() for r in results)


def test_wiki_search_two_vaults_no_cross_leak(require_markdown_oxide, two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    ra = wiki_search("note-a", cwd=str(a))
    rb = wiki_search("note-a", cwd=str(b))
    assert any("note-a" in r.get("name", "").lower() for r in ra)
    assert not any("note-a" in r.get("name", "").lower() for r in rb)


def test_wiki_search_no_rg_invocation(monkeypatch, require_markdown_oxide, fixture_vault: Path):
    import subprocess as sp
    real_run = sp.run

    def guarded(args, *a, **kw):
        if isinstance(args, list) and args and args[0] == "rg":
            raise AssertionError("wiki_search must not invoke ripgrep")
        return real_run(args, *a, **kw)

    monkeypatch.setattr(sp, "run", guarded)
    wiki_search("alpha", cwd=str(fixture_vault))
```

**Step 2: Run to confirm failure**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_wiki_search.py -v
```

Expected: the `no_rg_invocation` test fails.

**Step 3: Rewrite the body**

Add the `_SYMBOL_KIND_NAMES` table near module top:

```python
_SYMBOL_KIND_NAMES = {
    1: "File", 2: "Module", 3: "Namespace", 4: "Package", 5: "Class",
    6: "Method", 7: "Property", 8: "Field", 9: "Constructor", 10: "Enum",
    11: "Interface", 12: "Function", 13: "Variable", 14: "Constant",
    15: "String", 16: "Number", 17: "Boolean", 18: "Array", 19: "Object",
    20: "Key", 21: "Null", 22: "EnumMember", 23: "Struct", 24: "Event",
    25: "Operator", 26: "TypeParameter",
}
```

Replace `wiki_search` (lines 229-312) with:

```python
@mcp.tool()
def wiki_search(query: str, cwd: str | None = None) -> list[dict]:
    """Search vault notes via markdown-oxide LSP workspaceSymbol.

    Returns up to 50 symbols matching `query` substring (case-insensitive).
    Each result includes `name`, `kind` (LSP SymbolKind name), and `path`.
    LSP-backed — note headings, filenames, and frontmatter/heading tags
    surface here. Inline #tag body markers are not indexed by
    markdown-oxide; use wiki_grep for raw text lookup.
    """
    vault = _resolve_call_vault(cwd)
    if vault is None:
        return [{"error": f"no vault marker above {cwd or Path.cwd()}"}]
    q = query.strip()
    if not q:
        return []
    client = _pool.get(vault)
    try:
        symbols = client.workspace_symbol(q)
    except TimeoutError as e:
        return [{"error": f"lsp timeout: {e}"}]
    out: list[dict] = []
    for sym in symbols[:50]:
        loc = sym.get("location") or {}
        uri = loc.get("uri", "")
        path = uri.removeprefix("file://") if uri.startswith("file://") else uri
        out.append({
            "name": sym.get("name", ""),
            "kind": _SYMBOL_KIND_NAMES.get(sym.get("kind"), str(sym.get("kind"))),
            "path": path,
        })
    return out
```

**Step 4: Run the tests, confirm they pass**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_wiki_search.py -v
```

Expected: 4 tests PASS.

**Step 5: Commit**

```bash
git add claude/mcp/wiki-oxide/server.py claude/mcp/wiki-oxide/tests/test_wiki_search.py
git commit -m "feat(claude/mcp/wiki-oxide): restore LSP-backed wiki_search via workspace/symbol"
```

---

## Task 6: Restore LSP-backed `wiki_references`

Replace the ripgrep wikilink regex in `wiki_references` (lines 498-531) with a `textDocument/references` request.

**Files:**
- Test: `claude/mcp/wiki-oxide/tests/test_wiki_references.py` (new)
- Modify: `claude/mcp/wiki-oxide/server.py` — `wiki_references` body; add `LspClient.references()` method.

**Step 1: Write the failing test**

```python
"""wiki_references must be LSP-backed and per-call-vault aware."""
from pathlib import Path

import pytest

from server import wiki_references


def test_wiki_references_finds_backlinks(require_markdown_oxide, fixture_vault: Path):
    refs = wiki_references("beta", cwd=str(fixture_vault))
    assert any("alpha" in r.get("path", "") for r in refs)


def test_wiki_references_no_self_link(require_markdown_oxide, fixture_vault: Path):
    refs = wiki_references("alpha", cwd=str(fixture_vault))
    assert not any("alpha.md" in r.get("path", "") for r in refs)


def test_wiki_references_no_rg(monkeypatch, require_markdown_oxide, fixture_vault: Path):
    import subprocess as sp
    real_run = sp.run

    def guarded(args, *a, **kw):
        if isinstance(args, list) and args and args[0] == "rg":
            raise AssertionError("wiki_references must not invoke ripgrep")
        return real_run(args, *a, **kw)

    monkeypatch.setattr(sp, "run", guarded)
    wiki_references("beta", cwd=str(fixture_vault))
```

**Step 2: Run to confirm failure**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_wiki_references.py -v
```

Expected: the `no_rg` test fails.

**Step 3: Add `LspClient.references()` and rewrite the tool**

Add to `LspClient` (after `workspace_symbol`):

```python
def references(self, uri: str, line: int = 0, character: int = 0) -> list[dict]:
    """LSP textDocument/references — backlinks to the note at `uri`."""
    self._notify("textDocument/didOpen", {
        "textDocument": {"uri": uri, "languageId": "markdown",
                          "version": 1, "text": ""},
    })
    resp = self._request("textDocument/references", {
        "textDocument": {"uri": uri},
        "position": {"line": line, "character": character},
        "context": {"includeDeclaration": False},
    })
    return resp.get("result") or []
```

Replace `wiki_references` (lines 498-531):

```python
@mcp.tool()
def wiki_references(name: str, cwd: str | None = None) -> list[dict]:
    """Find backlinks to a wiki note via markdown-oxide LSP references.

    Backed by `textDocument/references` against the resolved note URI.
    Wikilink forms `[[name]]`, `[[name#heading]]`, `[[name|alias]]` and
    markdown `](name.md)` style links all surface here, depending on
    markdown-oxide's reference resolution.
    """
    vault = _resolve_call_vault(cwd)
    if vault is None:
        return [{"error": f"no vault marker above {cwd or Path.cwd()}"}]
    p = _resolve_note(vault, name)
    if p is None:
        return [{"error": f"note not found: {name}"}]
    client = _pool.get(vault)
    uri = f"file://{p}"
    try:
        locations = client.references(uri)
    except TimeoutError as e:
        return [{"error": f"lsp timeout: {e}"}]
    self_real = str(p)
    out: list[dict] = []
    for loc in locations:
        loc_uri = loc.get("uri", "")
        loc_path = loc_uri.removeprefix("file://") if loc_uri.startswith("file://") else loc_uri
        if loc_path == self_real:
            continue
        rng = loc.get("range", {}).get("start", {})
        out.append({
            "path": loc_path,
            "line": rng.get("line"),
            "character": rng.get("character"),
        })
    return out
```

**Step 4: Run the tests, confirm they pass**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_wiki_references.py -v
```

Expected: 3 tests PASS.

**Step 5: Commit**

```bash
git add claude/mcp/wiki-oxide/server.py claude/mcp/wiki-oxide/tests/test_wiki_references.py
git commit -m "feat(claude/mcp/wiki-oxide): restore LSP-backed wiki_references via textDocument/references"
```

---

## Task 7: Restore LSP-backed `wiki_tags`, document inline-tag limitation

Replace the ripgrep PCRE2 body-tag regex in `wiki_tags` (lines 315-356) with a `workspace/symbol` request filtered by `SymbolKind.Constant`.

**Files:**
- Test: `claude/mcp/wiki-oxide/tests/test_wiki_tags.py` (new)
- Modify: `claude/mcp/wiki-oxide/server.py` — `wiki_tags` body

**Step 1: Write the failing test**

```python
"""wiki_tags must be LSP-backed; inline body tags are a documented gap."""
from pathlib import Path

import pytest

from server import wiki_tags


def test_wiki_tags_returns_list(require_markdown_oxide, fixture_vault: Path):
    tags = wiki_tags(cwd=str(fixture_vault))
    assert isinstance(tags, list)


def test_wiki_tags_no_rg(monkeypatch, require_markdown_oxide, fixture_vault: Path):
    import subprocess as sp
    real_run = sp.run

    def guarded(args, *a, **kw):
        if isinstance(args, list) and args and args[0] == "rg":
            raise AssertionError("wiki_tags must not invoke ripgrep")
        return real_run(args, *a, **kw)

    monkeypatch.setattr(sp, "run", guarded)
    wiki_tags(cwd=str(fixture_vault))


def test_wiki_tags_no_vault_returns_error(tmp_path: Path):
    result = wiki_tags(cwd=str(tmp_path))
    assert isinstance(result, list)
    assert result and result[0].startswith("error:")
```

**Step 2: Run to confirm failure**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_wiki_tags.py -v
```

Expected: `no_rg` test fails.

**Step 3: Rewrite the body**

Replace `wiki_tags` (lines 315-356) with:

```python
@mcp.tool()
def wiki_tags(prefix: str = "", cwd: str | None = None) -> list[str]:
    """List vault tags via markdown-oxide LSP workspaceSymbol.

    Returns frontmatter and heading-level tags only (markdown-oxide
    indexes them as SymbolKind.Constant). Limitation: inline body
    `#tag` markers are not surfaced — markdown-oxide does not index
    them as workspace symbols today. For raw inline-tag text use
    `wiki_grep("#tagname")` instead.

    `prefix` narrows by leading characters after `#` (e.g. "v" → tags
    starting with #v). Empty prefix returns all tags.
    """
    vault = _resolve_call_vault(cwd)
    if vault is None:
        return [f"error: no vault marker above {cwd or Path.cwd()}"]
    client = _pool.get(vault)
    try:
        symbols = client.workspace_symbol("#" + prefix if prefix else "#")
    except TimeoutError as e:
        return [f"error: lsp timeout: {e}"]
    tags = sorted({
        sym.get("name", "")
        for sym in symbols
        if sym.get("kind") == 14  # SymbolKind.Constant — markdown-oxide tags
        and sym.get("name", "").startswith("#" + prefix)
    })
    return tags
```

**Step 4: Run the tests, confirm they pass**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_wiki_tags.py -v
```

Expected: 3 tests PASS.

**Step 5: Commit**

```bash
git add claude/mcp/wiki-oxide/server.py claude/mcp/wiki-oxide/tests/test_wiki_tags.py
git commit -m "feat(claude/mcp/wiki-oxide): restore LSP-backed wiki_tags, document inline limitation"
```

---

## Task 8: Cache-staleness mitigation — `didChangeWatchedFiles` + stale-retry

Send `workspace/didChangeWatchedFiles` immediately before every `workspace/symbol` and `textDocument/references` request. On LSP timeout or broken-pipe, evict the pool entry and retry once with a fresh client.

**Files:**
- Test: `claude/mcp/wiki-oxide/tests/test_regression.py` (new)
- Modify: `claude/mcp/wiki-oxide/server.py` — add `LspClient.did_change_watched_files`, call it from the search/reference paths; add `_stale_retry` helper; wrap LSP calls.

**Step 1: Write the failing test**

```python
"""Regression tests — the two original bugs that caused the ripgrep swap."""
import time
from pathlib import Path

import pytest

from server import wiki_search, wiki_preview


def test_cache_staleness(require_markdown_oxide, fixture_vault: Path):
    initial = wiki_search("delta", cwd=str(fixture_vault))
    assert not any("delta" in r.get("name", "").lower() for r in initial)
    (fixture_vault / "delta.md").write_text("# Delta\n\nFresh note.\n")
    time.sleep(0.1)
    later = wiki_search("delta", cwd=str(fixture_vault))
    assert any("delta" in r.get("name", "").lower() for r in later), (
        "cache staleness — delta.md created after first query but not visible"
    )


def test_hover_wedge_does_not_hang(require_markdown_oxide, fixture_vault: Path):
    deadline = time.time() + 30
    for i in range(50):
        if time.time() > deadline:
            pytest.fail(f"wiki_preview hung — only completed {i} of 50")
        result = wiki_preview("alpha", cwd=str(fixture_vault))
        assert "alpha" in result.get("name", "").lower()
```

**Step 2: Run to confirm failure**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_regression.py -v
```

Expected: cache-staleness FAILS (no nudge yet). Hover-wedge may PASS — keep as guard.

**Step 3: Implement nudge + retry**

Add to `LspClient`:

```python
def did_change_watched_files(self, vault: Path):
    """Nudge the server to re-scan — sends Changed events for every .md in vault."""
    changes = []
    for p in vault.rglob("*.md"):
        changes.append({"uri": f"file://{p}", "type": 2})  # 2 = Changed
    if changes:
        self._notify("workspace/didChangeWatchedFiles", {"changes": changes})
```

Add module-level helper:

```python
def _stale_retry(vault: Path, fn, max_retries: int = 1):
    """Run `fn(client)` with up to `max_retries` fresh-client retries."""
    last_exc: Exception | None = None
    for _attempt in range(max_retries + 1):
        client = _pool.get(vault)
        try:
            return fn(client)
        except (TimeoutError, BrokenPipeError, ConnectionResetError) as e:
            last_exc = e
            _pool._clients.pop(vault.resolve(), None)
            if client.proc is not None:
                try:
                    client.proc.terminate()
                except Exception:
                    pass
            continue
    raise last_exc  # type: ignore[misc]
```

In `wiki_search`, `wiki_tags`, `wiki_references`: before calling the LSP method, call `client.did_change_watched_files(vault)`. Wrap the LSP call itself in `_stale_retry(vault, lambda c: c.<method>(...))`.

**Step 4: Run the tests, confirm they pass**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_regression.py -v
```

Expected: both tests PASS.

**Step 5: Commit**

```bash
git add claude/mcp/wiki-oxide/server.py claude/mcp/wiki-oxide/tests/test_regression.py
git commit -m "fix(claude/mcp/wiki-oxide): didChangeWatchedFiles cache nudge + stale-retry guard"
```

---

## Task 9: Multi-vault end-to-end test

End-to-end check that one MCP process can serve two vaults in one session without cross-leak.

**Files:**
- Test: `claude/mcp/wiki-oxide/tests/test_multi_vault.py` (new)

**Step 1: Write the test**

```python
"""End-to-end: one MCP server, two vaults, no cross-leak."""
from pathlib import Path

import pytest

from server import wiki_search, wiki_list, _pool


def test_multi_vault_round_trip(require_markdown_oxide, two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    files_a = wiki_list(cwd=str(a))
    files_b = wiki_list(cwd=str(b))
    assert files_a == ["note-a.md"]
    assert files_b == ["note-b.md"]

    sa = wiki_search("note", cwd=str(a))
    sb = wiki_search("note", cwd=str(b))
    names_a = {r.get("name", "").lower() for r in sa}
    names_b = {r.get("name", "").lower() for r in sb}
    assert any("note-a" in n for n in names_a)
    assert not any("note-b" in n for n in names_a)
    assert any("note-b" in n for n in names_b)
    assert not any("note-a" in n for n in names_b)

    assert len(_pool._clients) >= 2
```

**Step 2: Run and confirm passes**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/test_multi_vault.py -v
```

Expected: 1 test PASS.

**Step 3: Commit**

```bash
git add claude/mcp/wiki-oxide/tests/test_multi_vault.py
git commit -m "test(claude/mcp/wiki-oxide): multi-vault end-to-end no-cross-leak"
```

---

## Task 10: Update module docstring — remove stale "ripgrep-backed" claims

The module docstring at the top of `server.py` (lines 6-31) still says "All search/listing tools are ripgrep-backed (no LSP cache)…". Replace with an accurate description of the LSP-backed architecture.

**Files:**
- Modify: `claude/mcp/wiki-oxide/server.py` — lines 6-31.

**Step 1: Rewrite the module docstring**

Replace lines 6-31 with:

```python
"""
wiki-oxide MCP server.

Thin LSP-client adapter around markdown-oxide. Provides per-vault
PKMS primitives (search, references, tags) to Claude Code agents.

Vault is resolved per tool call via walk-up from an optional `cwd`
argument (falling back to the server's launch cwd). One persistent
markdown-oxide subprocess per distinct vault, pooled by vault path.

Tools:
  - wiki_root(cwd)              — vault root path
  - wiki_list(cwd)              — list all .md files in vault
  - wiki_search(query, cwd)     — LSP workspaceSymbol
  - wiki_tags(prefix, cwd)      — LSP workspaceSymbol filtered to SymbolKind.Constant
                                  (frontmatter/heading tags only; see limitation)
  - wiki_grep(pattern, cwd)     — explicit ripgrep over the vault (orthogonal to LSP)
  - wiki_read(name, cwd)        — filesystem read
  - wiki_preview(name, cwd)     — first ~1200 chars + ripgrep-derived backlinks
  - wiki_references(name, cwd)  — LSP textDocument/references

Known limitation: markdown-oxide does not index inline body `#tag` markers
as workspace symbols, so wiki_tags returns only frontmatter and heading
tags. Use wiki_grep("#tagname") for raw inline-tag text lookup.
"""
```

**Step 2: Commit**

```bash
git add claude/mcp/wiki-oxide/server.py
git commit -m "docs(claude/mcp/wiki-oxide): describe LSP-backed architecture in module docstring"
```

---

## Task 11: Neovim save-time `didChangeWatchedFiles` autocmd

Make the editor surface immune to the same cache-staleness symptom we fixed in the MCP — `BufWritePost` for `*.md` sends an explicit `didChangeWatchedFiles` notification to any attached `markdown_oxide` client.

**Files:**
- Modify: `nvim/plugins/lang-md.lua` — add an autocmd inside the existing plugin spec.

**Step 1: Add the autocmd**

Inside `nvim/plugins/lang-md.lua`, alongside the existing `nvim-lspconfig` entry, register:

```lua
{
  "neovim/nvim-lspconfig",
  init = function()
    vim.api.nvim_create_autocmd("BufWritePost", {
      pattern = "*.md",
      callback = function(args)
        local clients = vim.lsp.get_clients({ name = "markdown_oxide", bufnr = args.buf })
        for _, client in ipairs(clients) do
          client.notify("workspace/didChangeWatchedFiles", {
            changes = {
              { uri = vim.uri_from_bufnr(args.buf), type = 2 }, -- 2 = Changed
            },
          })
        end
      end,
    })
  end,
},
```

**Step 2: Manual smoke**

```bash
nvim /home/jan/.dotfiles/wiki/<some-note>.md
```

`:LspInfo` confirms `markdown_oxide` attaches. Save a buffer, then open another note in the same vault, confirm wikilink completion / backlinks see the change.

**Step 3: Commit**

```bash
git add nvim/plugins/lang-md.lua
git commit -m "feat(nvim/lang-md): notify markdown-oxide of save events via didChangeWatchedFiles"
```

---

## Task 12: Manual smoke verification in real vaults

Final integration check across both real vaults (`.dotfiles/wiki` and `acag/docs/wiki`).

**Files:** none modified. Verification only.

**Step 1: Restart Claude Code session**

The MCP server must reload the new `server.py`.

**Step 2: Agent verification — same session, two cwds**

In one Claude Code session, run:

```
wiki_root(cwd="/home/jan/.dotfiles")                    # → /home/jan/.dotfiles/wiki
wiki_root(cwd="/home/jan/repos/b3tchi/acag")            # → /home/jan/repos/b3tchi/acag/docs/wiki
wiki_search("2605", cwd="/home/jan/repos/b3tchi/acag")  # → acag story zettels
wiki_search("2605", cwd="/home/jan/.dotfiles")          # → dotfiles wiki entries (or none)
```

Expected: results never cross. `_pool._clients` holds 2 entries.

**Step 3: nvim verification**

Open a note in `.dotfiles/wiki/`, complete on `[[`, `gd` on a wikilink, `gr` for refs. Then open a note in `acag/docs/wiki/` in the same nvim session, repeat. `:LspInfo` shows each buffer's `markdown_oxide` rooted at its own vault.

**Step 4: Run full test suite**

```bash
cd /home/jan/.dotfiles && uv run --with pytest pytest claude/mcp/wiki-oxide/tests/ -v
```

Expected: all tests PASS (or SKIP if `markdown-oxide` unavailable).

**Step 5: Commit (no-op or follow-up)**

If everything passes, no commit needed beyond what previous tasks produced. If a problem surfaces, file a follow-up bd issue with the symptom and continue.

---

## Task 13: Restore `markdown-lsp` marketplace plugin (optional parity)

`svelte-lsp`, `nushell-lsp`, `json-lsp`, `yaml-lsp` all ship as marketplace plugins for consistency. Restoring `markdown-lsp` mirrors that pattern. This task is **optional** — skip if there is no concrete pain from the asymmetry; document the decision either way in the closing commit message.

**Files:**
- Create: `claude/marketplace/plugins/markdown-lsp/` (directory + manifest mirroring `nushell-lsp`)
- Modify: `claude/marketplace/.claude-plugin/marketplace.json` — re-add the `markdown-lsp` entry.

**Step 1: Mirror an existing LSP plugin**

Copy `claude/marketplace/plugins/nushell-lsp/` to `claude/marketplace/plugins/markdown-lsp/` and edit the manifest description for `markdown-oxide`. Confirm `cmd = ["markdown-oxide"]`, `filetypes = ["markdown"]`, and `root_markers` match what `lang-md.lua` already passes.

**Step 2: Re-register in `marketplace.json`**

Add to the `plugins` array:

```json
{
  "name": "markdown-lsp",
  "source": "./plugins/markdown-lsp",
  "description": "Markdown LSP integration via markdown-oxide"
}
```

**Step 3: Smoke**

```bash
claude plugin marketplace add ~/.dotfiles/claude/marketplace
claude plugin install markdown-lsp@dotfiles
```

Expected: plugin installs cleanly; `markdown-oxide` attaches to a `.md` buffer.

**Step 4: Commit**

```bash
git add claude/marketplace/plugins/markdown-lsp/ claude/marketplace/.claude-plugin/marketplace.json
git commit -m "feat(claude/marketplace): restore markdown-lsp plugin for parity with other LSPs"
```

---

## Success criteria (epic acceptance)

1. `wiki_search`, `wiki_tags`, and `wiki_references` call `markdown-oxide` LSP — no `subprocess.run(["rg", …])` in their bodies.
2. `wiki_grep` retained as an explicit, separately-named ripgrep tool.
3. Every `@mcp.tool()` accepts an optional `cwd: str | None = None`.
4. Vault resolved per call via `_detect_vault(cwd)`; `VAULT` module-level singleton removed.
5. `LspPool` holds one persistent `markdown-oxide` client per vault; restarts on death.
6. Cache-staleness regression test passes (file written between two queries visible in the second).
7. Hover-wedge regression test passes (50 sequential previews complete without hang).
8. Multi-vault round-trip test passes (`pool._clients` length ≥ 2 after two-vault session).
9. Neovim still works — multi-vault per buffer, save triggers `didChangeWatchedFiles`.
10. Module + tool docstrings describe LSP-backed reality; inline-tag limitation in `wiki_tags` is explicit.
11. Manual smoke against `.dotfiles/wiki` and `acag/docs/wiki` shows no cross-leak.

## Out-of-scope follow-ups (file separately as bd issues if pursued)

- Upstream PR to `markdown-oxide` to honor watcher events automatically (would let us drop the explicit `did_change_watched_files` nudge).
- Inline `#tag` indexing — only if tags become a priority.
- Cross-vault wikilink resolution.
- Replace `wiki_preview`'s ripgrep backlinks fallback with the LSP path (low-value optimisation).
