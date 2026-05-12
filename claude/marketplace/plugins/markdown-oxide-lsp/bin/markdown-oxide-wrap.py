#!/usr/bin/env python3
"""
LSP proxy around markdown-oxide.

Workaround for Claude Code LSP tool failing with "internal error" on
hover responses containing nested wikilinks/backticks. Hover responses
are simplified to plain text. Everything else passes through unchanged.
"""
import json
import os
import re
import subprocess
import sys
import threading
import traceback

LOG = open("/tmp/moxide-wrap.log", "ab", buffering=0)
SERVER_CMD = ["markdown-oxide"]


def log(msg):
    try:
        LOG.write(f"{msg}\n".encode("utf-8", errors="replace"))
    except Exception:
        pass


def read_message(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        key, _, val = line.decode("ascii", errors="replace").partition(":")
        headers[key.strip().lower()] = val.strip()
    length = int(headers.get("content-length", "0"))
    body = b""
    while len(body) < length:
        chunk = stream.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    return headers, body


def simplify_hover_contents(contents):
    if isinstance(contents, dict) and "value" in contents:
        text = contents.get("value", "")
    elif isinstance(contents, str):
        text = contents
    elif isinstance(contents, list):
        parts = []
        for c in contents:
            if isinstance(c, dict):
                parts.append(c.get("value", ""))
            else:
                parts.append(str(c))
        text = "\n".join(parts)
    else:
        text = str(contents)
    text = re.sub(r"\[\[([^\]]+)\]\]", r"\1", text)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if len(text) > 800:
        text = text[:800] + "…"
    return {"kind": "plaintext", "value": text}


def main():
    log(f"--- wrap start pid={os.getpid()} ---")
    proc = subprocess.Popen(
        SERVER_CMD,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=LOG,
        env=os.environ,
    )

    pending = {}
    pending_lock = threading.Lock()
    stdout_lock = threading.Lock()
    proc_stdin_lock = threading.Lock()

    def write_to_client(body):
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        with stdout_lock:
            sys.stdout.buffer.write(header + body)
            sys.stdout.buffer.flush()

    def write_to_server(body):
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        with proc_stdin_lock:
            proc.stdin.write(header + body)
            proc.stdin.flush()

    def client_to_server():
        try:
            while True:
                msg = read_message(sys.stdin.buffer)
                if msg is None:
                    log("client closed stdin")
                    try:
                        proc.stdin.close()
                    except Exception:
                        pass
                    return
                _, body = msg
                try:
                    obj = json.loads(body)
                    if "id" in obj and "method" in obj:
                        with pending_lock:
                            pending[obj["id"]] = obj["method"]
                except Exception as e:
                    log(f"c→s json parse err: {e}")
                try:
                    write_to_server(body)
                except Exception as e:
                    log(f"c→s write err: {e}")
                    return
        except Exception:
            log(f"c→s thread crash:\n{traceback.format_exc()}")

    def server_to_client():
        try:
            while True:
                msg = read_message(proc.stdout)
                if msg is None:
                    log("server closed stdout")
                    return
                _, body = msg
                intercepted = False
                try:
                    obj = json.loads(body)
                    method = obj.get("method")
                    sid = obj.get("id")

                    # Server→client request: auto-ack methods Claude Code can't handle.
                    if method in ("client/registerCapability",
                                  "client/unregisterCapability") and sid is not None:
                        reply = {"jsonrpc": "2.0", "id": sid, "result": None}
                        write_to_server(json.dumps(reply).encode("utf-8"))
                        log(f"auto-acked {method} id={sid}")
                        intercepted = True
                    elif method == "workspace/configuration" and sid is not None:
                        items = (obj.get("params") or {}).get("items") or []
                        reply = {"jsonrpc": "2.0", "id": sid,
                                 "result": [None] * len(items)}
                        write_to_server(json.dumps(reply).encode("utf-8"))
                        log(f"auto-acked workspace/configuration id={sid} n={len(items)}")
                        intercepted = True
                    else:
                        rid = obj.get("id")
                        if rid is not None and method is None:
                            # response to a client request
                            with pending_lock:
                                client_method = pending.pop(rid, None)
                            if client_method == "textDocument/hover" and obj.get("result"):
                                contents = obj["result"].get("contents")
                                if contents is not None:
                                    obj["result"]["contents"] = simplify_hover_contents(contents)
                                    body = json.dumps(obj).encode("utf-8")
                except Exception as e:
                    log(f"s→c parse/mutate err: {e}")
                if intercepted:
                    continue
                try:
                    write_to_client(body)
                except Exception as e:
                    log(f"s→c write err: {e}")
                    return
        except Exception:
            log(f"s→c thread crash:\n{traceback.format_exc()}")

    t1 = threading.Thread(target=client_to_server, daemon=True)
    t2 = threading.Thread(target=server_to_client, daemon=True)
    t1.start()
    t2.start()

    rc = proc.wait()
    log(f"--- server exited rc={rc} ---")
    # Give threads a moment to drain
    t1.join(timeout=1)
    t2.join(timeout=1)
    sys.exit(rc)


if __name__ == "__main__":
    main()
