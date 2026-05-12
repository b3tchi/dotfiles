#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp[cli]>=1.0"]
# ///
"""
wiki-oxide MCP server.

Provides vault search + read primitives to Claude Code as MCP tools.
All search/listing tools are ripgrep-backed (no LSP cache) because
markdown-oxide's workspaceSymbol index is stale on file change and
catalogues only headings/files/symbol-tags (not inline #tag body
markers).

Tools:
  - wiki_root()              — vault root path
  - wiki_list()              — list all .md files in vault
  - wiki_search(query)       — search filenames, headings, tags (ripgrep)
  - wiki_tags(prefix="")     — all #tags in vault, inline-aware (ripgrep)
  - wiki_grep(pattern, ...)  — generic ripgrep within vault
  - wiki_read(name)          — full text of a note
  - wiki_preview(name)       — first ~1200 chars + backlinks
  - wiki_references(name)    — backlinks via ripgrep

The LspClient (markdown-oxide stdio bridge) is retained for future
LSP-based features (e.g. hover, completion) but is no longer used by
the search tools. It will not be started unless something explicitly
calls get_client().

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

VAULT = Path(os.environ.get("WIKI_ROOT", str(Path.home() / ".dotfiles/wiki"))).resolve()


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


_client: LspClient | None = None
_client_lock = threading.Lock()


def get_client() -> LspClient:
    global _client
    with _client_lock:
        if _client is None or (_client.proc and _client.proc.poll() is not None):
            _client = LspClient(VAULT)
        return _client


# ---------- MCP server ----------
mcp = FastMCP("wiki-oxide")


@mcp.tool()
def wiki_search(query: str) -> list[dict]:
    """Search vault for filenames, headings, and tags matching the query.

    Backed by ripgrep — no LSP workspaceSymbol cache to go stale.
    Returns matches with `kind` set to `"file"`, `"heading"`, or `"tag"`.
    Results from each category are concatenated in that order. Total
    capped at 50.

    Examples:
      - "ovpn"   → filename + heading + tag substring matches
      - "#vpn"   → tag matches only (treats query as a tag)
      - "Inbox"  → heading + filename matches
    """
    q = query.strip()
    if not q:
        return []
    if not shutil.which("rg"):
        return [{"error": "ripgrep not installed"}]

    out: list[dict] = []

    # 1. Filename matches (case-insensitive substring on the stem).
    q_lower = q.lstrip("#").lower()
    if q_lower:
        for p in sorted(VAULT.rglob("*.md")):
            if q_lower in p.stem.lower():
                out.append(
                    {
                        "name": p.stem,
                        "kind": "file",
                        "path": str(p),
                        "match_field": "filename",
                    }
                )

    # 2. Heading matches — any line that's an H1-H6 containing the query.
    if not q.startswith("#"):
        # Escape regex meta in user query, build a heading-only pattern
        heading_pattern = rf"^#{{1,6}}\s+.*{re.escape(q)}"
        res = subprocess.run(
            ["rg", "-n", "--no-heading", "--color=never", "-i", "-e", heading_pattern, str(VAULT)],
            capture_output=True,
            text=True,
            check=False,
        )
        for line in res.stdout.splitlines():
            path, _, rest = line.partition(":")
            lineno_s, _, text = rest.partition(":")
            out.append(
                {
                    "name": text.strip().lstrip("#").strip(),
                    "kind": "heading",
                    "path": path,
                    "line": int(lineno_s) if lineno_s.isdigit() else None,
                    "match_field": "heading",
                }
            )

    # 3. Tag matches. Build a #tag pattern from the query.
    tag_token = q if q.startswith("#") else "#" + q
    # Match exactly that tag — bounded so #auth doesn't match #authentication.
    # PCRE2 needed for the trailing lookahead.
    tag_pattern = rf"(?:^|\s){re.escape(tag_token)}(?=[\s.,;:!?)\]\}}]|$)"
    res = subprocess.run(
        ["rg", "-P", "-n", "--no-heading", "--color=never", "-e", tag_pattern, str(VAULT)],
        capture_output=True,
        text=True,
        check=False,
    )
    for line in res.stdout.splitlines():
        path, _, rest = line.partition(":")
        lineno_s, _, text = rest.partition(":")
        out.append(
            {
                "name": tag_token,
                "kind": "tag",
                "path": path,
                "line": int(lineno_s) if lineno_s.isdigit() else None,
                "match_field": "tag",
            }
        )

    return out[:50]


@mcp.tool()
def wiki_tags(prefix: str = "") -> list[str]:
    """List distinct #tags in the vault via ripgrep.

    `prefix` narrows by leading characters after `#` (e.g. "v" → tags
    starting with #v). Empty prefix returns all tags.

    Backed by ripgrep — surfaces inline `#tag` body markers, not just
    LSP workspace symbols. Tags are tokenised as `#` followed by
    `[a-zA-Z0-9_-]+` and must be preceded by whitespace or line start
    (so URL fragments and code-block `#include` do not over-match).
    """
    if not shutil.which("rg"):
        return ["error: ripgrep not installed"]

    safe_prefix = re.escape(prefix)
    # PCRE2 lookbehind: require non-word context before the `#`.
    # Pattern: a `#`, then the user's prefix, then one or more
    # tag-name characters. The lookbehind keeps URL fragments out.
    pattern = rf"(?<![\w])#{safe_prefix}[A-Za-z][A-Za-z0-9_-]*"
    res = subprocess.run(
        [
            "rg",
            "-P",
            "--no-heading",
            "--no-filename",
            "--only-matching",
            "-e",
            pattern,
            str(VAULT),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    tags = sorted({line for line in res.stdout.splitlines() if line.startswith("#")})
    return tags


@mcp.tool()
def wiki_grep(pattern: str, max_results: int = 100) -> list[dict]:
    """Search vault file contents via ripgrep. Returns matching lines with paths.

    Pattern is treated as a regex by ripgrep. Examples:
      - "openvpn"
      - "^#\\s"              (top-level headings)
      - "\\[\\[.+?\\]\\]"    (any wikilink)
    """
    if not shutil.which("rg"):
        return [{"error": "ripgrep not installed"}]
    res = subprocess.run(
        ["rg", "-n", "--no-heading", "--color=never", pattern, str(VAULT)],
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
def wiki_list() -> list[str]:
    """List all markdown files in the vault, relative to the vault root."""
    return sorted(str(p.relative_to(VAULT)) for p in VAULT.rglob("*.md"))


@mcp.tool()
def wiki_root() -> str:
    """Return the configured vault root path."""
    return str(VAULT)


def _resolve_note(name: str) -> Path | None:
    """Resolve a wikilink-style name or relative path to an absolute Path."""
    p = Path(name)
    if p.is_absolute() and p.exists() and str(p).startswith(str(VAULT)):
        return p
    candidate = (VAULT / name).with_suffix("") if name.endswith(".md") else VAULT / f"{name}.md"
    # Try as-given (with or without .md)
    for cand in (
        VAULT / name,
        VAULT / f"{name}.md",
        candidate.with_suffix(".md"),
    ):
        if cand.is_file():
            return cand
    # Search by basename across vault
    base = Path(name).stem
    matches = list(VAULT.rglob(f"{base}.md"))
    if len(matches) == 1:
        return matches[0]
    return None


@mcp.tool()
def wiki_read(name: str) -> dict:
    """Read full content of a wiki note.

    `name` accepts wikilink-style names ("ovpn-home"), relative paths
    ("notes/ovpn-home.md"), or absolute paths within the vault.
    """
    p = _resolve_note(name)
    if p is None:
        return {"error": f"note not found: {name}"}
    try:
        text = p.read_text(errors="replace")
    except Exception as e:
        return {"error": f"read failed: {e}", "path": str(p)}
    return {
        "path": str(p),
        "relative": str(p.relative_to(VAULT)),
        "content": text,
        "lines": text.count("\n") + 1,
    }


_PREVIEW_MAX_CHARS = 1200


@mcp.tool()
def wiki_preview(name: str) -> dict:
    """Compact file preview + backlinks for a wiki note.

    Returns the first ~1200 chars of the note plus any backlinks found
    via ripgrep. For full text use `wiki_read`; for backlinks only use
    `wiki_references`. Built directly from the filesystem — no LSP
    hover involved (markdown-oxide hover wedges after a few calls).
    """
    target = Path(name).stem
    p = _resolve_note(name)
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
            ["rg", "-n", "--no-heading", "--color=never", pattern, str(VAULT)],
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
def wiki_references(name: str) -> list[dict]:
    """Find backlinks to a wiki note via ripgrep.

    Matches wikilink forms `[[name]]`, `[[name#heading]]`, `[[name|alias]]`
    and markdown links `](name.md)` / `](name#heading)`. Skips the target
    note itself.
    """
    target = Path(name).stem
    if not shutil.which("rg"):
        return [{"error": "ripgrep not installed"}]
    pattern = (
        rf"\[\[{re.escape(target)}(?:#[^\]]*)?(?:\|[^\]]*)?\]\]"
        rf"|\]\([^)]*?{re.escape(target)}(?:\.md)?(?:#[^)]*)?\)"
    )
    res = subprocess.run(
        ["rg", "-n", "--no-heading", "--color=never", pattern, str(VAULT)],
        capture_output=True,
        text=True,
        check=False,
    )
    p = _resolve_note(name)
    self_real = str(p) if p else None
    out: list[dict] = []
    for line in res.stdout.splitlines():
        path, _, rest = line.partition(":")
        if path == self_real:
            continue
        lineno_s, _, text = rest.partition(":")
        out.append(
            {"path": path, "line": int(lineno_s) if lineno_s.isdigit() else None,
             "text": text}
        )
    return out


if __name__ == "__main__":
    if not VAULT.exists():
        print(f"WIKI_ROOT does not exist: {VAULT}", file=sys.stderr)
        sys.exit(1)
    mcp.run()
