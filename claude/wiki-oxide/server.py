#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp[cli]>=1.0"]
# ///
"""
wiki-oxide MCP server.

Provides vault search + read primitives to Claude Code as MCP tools.
wiki_search is LSP-backed via markdown-oxide workspaceSymbol. All other
search/listing tools are ripgrep-backed for inline #tag body markers and
raw text lookup that the LSP index does not cover.

Tools:
  - wiki_root()              — vault root path
  - wiki_list()              — list all .md files in vault
  - wiki_search(query)       — search filenames, headings, tags (LSP workspaceSymbol)
  - wiki_tags(prefix="")     — all #tags in vault, inline-aware (ripgrep)
  - wiki_grep(pattern, ...)  — generic ripgrep within vault
  - wiki_read(name)          — full text of a note
  - wiki_preview(name)       — first ~1200 chars + backlinks
  - wiki_references(name)    — backlinks via ripgrep

wiki_search result shape (as of wq0.5): {"name", "kind" (LSP SymbolKind
name string), "path"}. Breaking change from pre-wq0.5: "kind" values
changed from "file"/"heading"/"tag" to LSP SymbolKind names (e.g. "File",
"String"); "line" and "match_field" fields removed.

Configure vault root via env var WIKI_ROOT (default ~/.dotfiles/wiki).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

from mcp.server.fastmcp import FastMCP

_VAULT_MARKERS = (".moxide.toml", ".obsidian")
_DESCEND_MAX_DEPTH = 4


def _has_marker(d: Path) -> bool:
    return any((d / m).exists() for m in _VAULT_MARKERS)


def _walk_up(start: Path) -> Path | None:
    for d in (start, *start.parents):
        if _has_marker(d):
            return d
    return None


def _walk_down(start: Path) -> Path | None:
    # BFS bounded by depth so we don't scan huge trees.
    queue = [(start, 0)]
    while queue:
        d, depth = queue.pop(0)
        if _has_marker(d):
            return d
        if depth >= _DESCEND_MAX_DEPTH:
            continue
        try:
            for child in d.iterdir():
                if child.is_dir() and not child.name.startswith("."):
                    queue.append((child, depth + 1))
        except (PermissionError, OSError):
            pass
    return None


def _detect_vault(cwd: Path) -> Path | None:
    """Detect the vault root from `cwd`.

    Search strategy:
    1. If WIKI_ROOT env var is set, use it — but return None if the path does
       not exist on disk (behavior change from old code which returned it
       unconditionally, producing silent failures downstream).
    2. Walk up from `cwd` looking for a vault marker (.moxide.toml, .obsidian).
    3. If no marker found upward, BFS downward up to _DESCEND_MAX_DEPTH levels.
    4. Return None if no vault is detected.
    """
    env = os.environ.get("WIKI_ROOT")
    if env:
        p = Path(env).resolve()
        return p if p.exists() else None
    found = _walk_up(cwd) or _walk_down(cwd)
    if found is not None:
        return found.resolve()
    return None


def _resolve_call_vault(cwd: str | None) -> Path | None:
    """Resolve the vault for a single MCP tool call."""
    start = Path(cwd).resolve() if cwd else Path.cwd()
    return _detect_vault(start)


_SYMBOL_KIND_NAMES = {
    1: "File", 2: "Module", 3: "Namespace", 4: "Package", 5: "Class",
    6: "Method", 7: "Property", 8: "Field", 9: "Constructor", 10: "Enum",
    11: "Interface", 12: "Function", 13: "Variable", 14: "Constant",
    15: "String", 16: "Number", 17: "Boolean", 18: "Array", 19: "Object",
    20: "Key", 21: "Null", 22: "EnumMember", 23: "Struct", 24: "Event",
    25: "Operator", 26: "TypeParameter",
}

# LSP SymbolKind values markdown-oxide uses for tag-like workspace symbols.
# Update this set rather than the filter expression if a new release adds kinds.
# Note: markdown-oxide uses Constant (14) for inline body `#tag` markers.
# Frontmatter `tags: [...]` entries are NOT indexed as workspace symbols.
_TAG_SYMBOL_KINDS = frozenset({14})  # SymbolKind.Constant


class LspClient:
    """Thin LSP client over markdown-oxide stdio, holds one persistent server."""

    def __init__(self, cwd: Path):
        self.cwd = cwd
        self.proc: subprocess.Popen | None = None
        self.lock = threading.Lock()
        self.id_lock = threading.Lock()
        self.next_id = 1
        self.responses: dict[int, dict] = {}
        self.events: dict[int, threading.Event] = {}
        self.events_lock = threading.Lock()
        self.reader_thread: threading.Thread | None = None
        self.start()

    def start(self):
        self.proc = subprocess.Popen(
            ["markdown-oxide"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=str(self.cwd),
        )
        self.reader_thread = threading.Thread(target=self._reader, daemon=True)
        self.reader_thread.start()
        self._initialize()

    def _reader(self):
        assert self.proc and self.proc.stdout
        stream = self.proc.stdout
        while True:
            headers = {}
            while True:
                line = stream.readline()
                if not line:
                    return
                if line in (b"\r\n", b"\n"):
                    break
                key, _, val = line.decode("ascii", "replace").partition(":")
                headers[key.strip().lower()] = val.strip()
            length = int(headers.get("content-length", "0"))
            body = b""
            while len(body) < length:
                chunk = stream.read(length - len(body))
                if not chunk:
                    return
                body += chunk
            try:
                msg = json.loads(body)
            except Exception:
                continue
            # auto-ack dynamic registration so server doesn't panic
            if msg.get("method") in (
                "client/registerCapability",
                "client/unregisterCapability",
            ) and "id" in msg:
                self._send_raw({"jsonrpc": "2.0", "id": msg["id"], "result": None})
                continue
            if msg.get("method") == "workspace/configuration" and "id" in msg:
                items = (msg.get("params") or {}).get("items") or []
                self._send_raw(
                    {"jsonrpc": "2.0", "id": msg["id"], "result": [None] * len(items)}
                )
                continue
            rid = msg.get("id")
            if rid is not None and "method" not in msg:
                self.responses[rid] = msg
                with self.events_lock:
                    ev = self.events.get(rid)
                if ev is not None:
                    ev.set()

    def _send_raw(self, msg: dict):
        assert self.proc and self.proc.stdin
        body = json.dumps(msg).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        with self.lock:
            self.proc.stdin.write(header + body)
            self.proc.stdin.flush()

    def _request(self, method: str, params: dict, timeout: float = 8.0) -> dict:
        with self.id_lock:
            rid = self.next_id
            self.next_id += 1
        ev = threading.Event()
        with self.events_lock:
            self.events[rid] = ev
        try:
            self._send_raw({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
            if not ev.wait(timeout=timeout):
                raise TimeoutError(f"{method} timed out after {timeout}s")
            return self.responses.pop(rid)
        finally:
            with self.events_lock:
                self.events.pop(rid, None)
            self.responses.pop(rid, None)

    def _notify(self, method: str, params: dict):
        self._send_raw({"jsonrpc": "2.0", "method": method, "params": params})

    def _initialize(self):
        uri = f"file://{self.cwd}"
        self._request(
            "initialize",
            {
                "processId": None,
                "rootUri": uri,
                "workspaceFolders": [{"uri": uri, "name": self.cwd.name}],
                "capabilities": {},
            },
            timeout=10,
        )
        self._notify("initialized", {})

    def workspace_symbol(self, query: str) -> list[dict]:
        resp = self._request("workspace/symbol", {"query": query})
        return resp.get("result") or []

    def references(self, uri: str, path: Path, line: int = 1, character: int = 0) -> list[dict]:
        """LSP textDocument/references — backlinks to the note at `uri`.

        Sends `didOpen` with the actual file content so markdown-oxide's
        document store matches disk. Position (line=1, character=0) is the
        first body line after the heading — markdown-oxide returns all
        document backlinks from any body position. The heading line (line=0)
        returns empty because markdown-oxide does not resolve the heading
        token as a wikilink target.

        Note: `didClose` is intentionally omitted. Sending didClose causes
        the server to enter a state where subsequent textDocument/references
        calls on the same URI time out. Re-sending didOpen on each call is
        idempotent in markdown-oxide and keeps the server state coherent.
        """
        try:
            text = path.read_text(errors="replace")
        except Exception:
            text = ""
        self._notify("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "markdown",
                              "version": 1, "text": text},
        })
        resp = self._request("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": character},
            "context": {"includeDeclaration": False},
        })
        return resp.get("result") or []


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


# ---------- MCP server ----------
mcp = FastMCP("wiki-oxide")


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


@mcp.tool()
def wiki_tags(prefix: str = "", cwd: str | None = None) -> list[str]:
    """List vault tags via markdown-oxide LSP workspaceSymbol.

    Returns inline body `#tag` markers (markdown-oxide indexes them as
    SymbolKind.Constant). Limitation: frontmatter `tags: [...]` entries
    are NOT surfaced — markdown-oxide does not index them as workspace
    symbols. For frontmatter tag lookup use `wiki_grep("tags:")` instead.

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
        if sym.get("kind") in _TAG_SYMBOL_KINDS
        and sym.get("name", "").startswith("#" + prefix)
    })
    return tags


@mcp.tool()
def wiki_grep(pattern: str, max_results: int = 100, cwd: str | None = None) -> list[dict]:
    """Search vault file contents via ripgrep. Returns matching lines with paths.

    Pattern is treated as a regex by ripgrep. Examples:
      - "openvpn"
      - "^#\\s"              (top-level headings)
      - "\\[\\[.+?\\]\\]"    (any wikilink)
    """
    vault = _resolve_call_vault(cwd)
    if vault is None:
        return [{"error": "no vault detected: run from a directory containing .moxide.toml or .obsidian, or set WIKI_ROOT"}]
    if not shutil.which("rg"):
        return [{"error": "ripgrep not installed"}]
    res = subprocess.run(
        ["rg", "-n", "--no-heading", "--color=never", pattern, str(vault)],
        capture_output=True,
        text=True,
        check=False,
    )
    out = []
    for line in res.stdout.splitlines()[:max_results]:
        path, _, rest = line.partition(":")
        lineno, _, text = rest.partition(":")
        out.append({"path": path, "line": int(lineno) if lineno.isdigit() else None,
                    "text": text})
    return out


@mcp.tool()
def wiki_list(cwd: str | None = None) -> list[str]:
    """List all markdown files in the vault, relative to the vault root."""
    vault = _resolve_call_vault(cwd)
    if vault is None:
        return ["error: no vault detected: run from a directory containing .moxide.toml or .obsidian, or set WIKI_ROOT"]
    return sorted(str(p.relative_to(vault)) for p in vault.rglob("*.md"))


@mcp.tool()
def wiki_root(cwd: str | None = None) -> str:
    """Return the configured vault root path."""
    vault = _resolve_call_vault(cwd)
    if vault is None:
        return "error: no vault detected: run from a directory containing .moxide.toml or .obsidian, or set WIKI_ROOT"
    return str(vault)


def _resolve_note(vault: Path, name: str) -> Path | None:
    """Resolve a wikilink-style name or relative path to an absolute Path."""
    p = Path(name)
    if p.is_absolute() and p.exists() and str(p).startswith(str(vault)):
        return p
    candidate = (vault / name).with_suffix("") if name.endswith(".md") else vault / f"{name}.md"
    # Try as-given (with or without .md)
    for cand in (
        vault / name,
        vault / f"{name}.md",
        candidate.with_suffix(".md"),
    ):
        if cand.is_file():
            return cand
    # Search by basename across vault
    base = Path(name).stem
    matches = list(vault.rglob(f"{base}.md"))
    if len(matches) == 1:
        return matches[0]
    return None


@mcp.tool()
def wiki_read(name: str, cwd: str | None = None) -> dict:
    """Read full content of a wiki note.

    `name` accepts wikilink-style names ("ovpn-home"), relative paths
    ("notes/ovpn-home.md"), or absolute paths within the vault.
    """
    vault = _resolve_call_vault(cwd)
    if vault is None:
        return {"error": "no vault detected: run from a directory containing .moxide.toml or .obsidian, or set WIKI_ROOT"}
    p = _resolve_note(vault, name)
    if p is None:
        return {"error": f"note not found: {name}"}
    try:
        text = p.read_text(errors="replace")
    except Exception as e:
        return {"error": f"read failed: {e}", "path": str(p)}
    return {
        "path": str(p),
        "relative": str(p.relative_to(vault)),
        "content": text,
        "lines": text.count("\n") + 1,
    }


_PREVIEW_MAX_CHARS = 1200


@mcp.tool()
def wiki_preview(name: str, cwd: str | None = None) -> dict:
    """Compact file preview + backlinks for a wiki note.

    Returns the first ~1200 chars of the note plus any backlinks found
    via ripgrep. For full text use `wiki_read`; for backlinks only use
    `wiki_references`. Built directly from the filesystem — no LSP
    hover involved (markdown-oxide hover wedges after a few calls).
    """
    vault = _resolve_call_vault(cwd)
    if vault is None:
        return {"error": "no vault detected: run from a directory containing .moxide.toml or .obsidian, or set WIKI_ROOT"}
    target = Path(name).stem
    p = _resolve_note(vault, name)
    if p is None:
        return {"error": f"note not found: {target}"}
    try:
        text = p.read_text(errors="replace")
    except Exception as e:
        return {"error": f"read failed: {e}", "path": str(p)}
    truncated = len(text) > _PREVIEW_MAX_CHARS
    preview = text[:_PREVIEW_MAX_CHARS] + ("\n…" if truncated else "")

    backlinks: list[dict] = []
    if shutil.which("rg"):
        pattern = (
            rf"\[\[{re.escape(target)}(?:#[^\]]*)?(?:\|[^\]]*)?\]\]"
            rf"|\]\([^)]*?{re.escape(target)}(?:\.md)?(?:#[^)]*)?\)"
        )
        res = subprocess.run(
            ["rg", "-n", "--no-heading", "--color=never", pattern, str(vault)],
            capture_output=True,
            text=True,
            check=False,
        )
        self_real = str(p)
        for line in res.stdout.splitlines():
            path, _, rest = line.partition(":")
            if path == self_real:
                continue
            lineno_s, _, line_text = rest.partition(":")
            backlinks.append(
                {
                    "path": path,
                    "line": int(lineno_s) if lineno_s.isdigit() else None,
                    "text": line_text,
                }
            )
    return {
        "name": target,
        "path": str(p),
        "preview": preview,
        "truncated": truncated,
        "backlinks": backlinks,
    }


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
        locations = client.references(uri, p)
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


if __name__ == "__main__":
    _startup_vault = _detect_vault(Path.cwd())
    if _startup_vault is None:
        print(
            "wiki-oxide: no vault detected.\n"
            "Run from a directory containing a vault marker (.moxide.toml or .obsidian),\n"
            "or set the WIKI_ROOT environment variable to an existing vault path.",
            file=sys.stderr,
        )
        sys.exit(1)
    mcp.run()
