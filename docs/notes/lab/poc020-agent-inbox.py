#!/usr/bin/env python3
"""agent-inbox -- REFERENCE IMPLEMENTATION from [[poc020]]. NOT production code.

Throwaway PoC artifact, kept only because the findings in poc020 are easier to
read against real source. It has no tests, no error handling worth the name, and
several known defects listed at the bottom. Build the shipped version fresh
through the lifecycle; do not promote this file.

The agent side knows exactly one thing: `agent-inbox ask "<question>"`.
Launched with the Bash tool's run_in_background=true, it parks the agent; the
harness re-invokes the agent when the command exits. That is the whole channel --
no Stop hook, no tmux nudge, no monitor subagent (see poc020 ## recommendation).

The operator side is a directory. No command is required: open the folder, type
under '# reply', save. The operator subcommands below are conveniences only.

Store location, in precedence order:
  $AGENT_INBOX                       explicit override
  $XDG_STATE_HOME/agent-inbox        (adr0013 precedent: XDG_STATE_HOME, 0700)
  ~/.local/state/agent-inbox
"""
import argparse, os, re, subprocess, sys, time
from pathlib import Path


def store() -> Path:
    if v := os.environ.get("AGENT_INBOX"):
        p = Path(v)
    else:
        base = os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local/state")
        p = Path(base) / "agent-inbox"
    (p / "sent").mkdir(parents=True, exist_ok=True)
    p.chmod(0o700)
    return p


def agent_id() -> str:
    """Address of the asking agent. Derived, never supplied by the agent."""
    for var in ("AGENT_NAME", "TMUX_PANE"):
        if v := os.environ.get(var):
            return re.sub(r"\W+", "", v) or "agent"
    return f"pid{os.getppid()}"


def slug(s: str, n: int = 48) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", s.lower())).strip("-")[:n]


REPLY_RE = re.compile(r"^# reply\s*$", re.M)


def reply_of(text: str) -> str:
    if not (m := REPLY_RE.search(text)):
        return ""
    body = text[m.end():]
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    return body.strip()


def question_of(p: Path) -> str:
    return p.read_text().split("# reply")[0].replace("# question", "").strip()


def pending(d: Path):
    return sorted(p for p in d.glob("*.md") if p.is_file())


def new_path(d: Path, question: str) -> Path:
    """Filename is for the OPERATOR, who reads this folder in nvim/yazi and never
    runs a command -- so it says who is asking and what about.

    Idempotent: re-asking the SAME question resumes the existing request instead
    of minting a new one. Without this, a caller retrying after a Bash-tool
    timeout orphans its own earlier question (poc020 ## result)."""
    aid = agent_id()
    for p in pending(d):
        if question_of(p).endswith(question.strip()):
            return p
    stem = f"{aid}--{slug(question)}"
    p = d / f"{stem}.md"
    n = 2
    while p.exists():
        p = d / f"{stem}-{n}.md"
        n += 1
    return p


def cmd_ask(a) -> int:
    d = store()
    f = new_path(d, a.question)
    if not f.exists():
        f.write_text(
            f"# question\n\nfrom: {agent_id()}\n\n{a.question}\n\n"
            "# reply\n\n"
            "<!-- Type your answer below this line and save the file.\n"
            "     That is the whole protocol - no command to run.\n"
            "     The file disappears into sent/ once the agent has it. -->\n\n"
        )
    elif body := reply_of(f.read_text()):
        # answered while we were away between retries
        f.rename(d / "sent" / f"{f.stem}.answered.md")
        print(body)
        return 0
    if not a.quiet:
        print(f"[agent-inbox] waiting for operator ({f.name})", file=sys.stderr)
    mt, deadline = f.stat().st_mtime, time.time() + a.timeout
    while time.time() < deadline:
        try:
            cur = f.stat().st_mtime
        except FileNotFoundError:
            print("request file vanished", file=sys.stderr)
            return 3
        if cur != mt:
            if body := reply_of(f.read_text()):
                f.rename(d / "sent" / f"{f.stem}.answered.md")
                print(body)
                return 0
            mt = cur
        time.sleep(0.4)
    print(f"TIMEOUT: no operator reply within {a.timeout}s", file=sys.stderr)
    return 2


def cmd_list(a) -> int:
    for p in pending(store()):
        q = question_of(p)
        print(f"{p.stem}\t{q.splitlines()[-1] if q else '(empty)'}")
    return 0


def cmd_show(a) -> int:
    p = store() / f"{a.id}.md"
    if not p.exists():
        print(f"no pending request {a.id}", file=sys.stderr)
        return 1
    print(p.read_text(), end="")
    return 0


def cmd_answer(a) -> int:
    p = store() / f"{a.id}.md"
    if not p.exists():
        print(f"no pending request {a.id}", file=sys.stderr)
        return 1
    with p.open("a") as fh:
        fh.write(a.text + "\n")
    print(f"answered {a.id}")
    return 0


def cmd_reply(a) -> int:
    """Interactive: show each pending question, type the answer inline."""
    d = store()
    items = [p for p in pending(d) if not a.id or p.stem == a.id]
    if not items:
        print("no pending requests", file=sys.stderr)
        return 1
    answered = 0
    for p in items:
        print(f"\n\033[1m{p.stem}\033[0m  {question_of(p)}")
        try:
            text = input("reply> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not text:
            print("(skipped)")
            continue
        with p.open("a") as fh:
            fh.write(text + "\n")
        answered += 1
        print("sent")
    print(f"\n{answered} answered, {len(pending(d))} still pending")
    return 0


def cmd_edit(a) -> int:
    p = store() / f"{a.id}.md"
    if not p.exists():
        print(f"no pending request {a.id}", file=sys.stderr)
        return 1
    return subprocess.call([os.environ.get("EDITOR", "nvim"), str(p)])


def cmd_watch(a) -> int:
    seen = set()
    while True:
        for p in pending(store()):
            if p.stem not in seen:
                seen.add(p.stem)
                print(f"{p.stem}\t{question_of(p)}", flush=True)
        time.sleep(1)


def main() -> int:
    ap = argparse.ArgumentParser(prog="agent-inbox")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("ask", help="agent side: ask, block, print the reply")
    s.add_argument("question")
    # 110s: must stay under the Bash tool's 120s DEFAULT timeout, or a foreground
    # call is killed mid-block and fails messily instead of returning exit 2.
    # Background callers should pass a much larger value.
    s.add_argument("--timeout", type=int, default=110)
    s.add_argument("--quiet", action="store_true")
    s.set_defaults(fn=cmd_ask)

    for name, fn, helptext in (
        ("list", cmd_list, "operator: pending requests"),
        ("watch", cmd_watch, "operator: stream new requests"),
    ):
        s = sub.add_parser(name, help=helptext)
        s.set_defaults(fn=fn)

    for name, fn, helptext in (
        ("show", cmd_show, "operator: print one request"),
        ("edit", cmd_edit, "operator: open one request in $EDITOR"),
    ):
        s = sub.add_parser(name, help=helptext)
        s.add_argument("id")
        s.set_defaults(fn=fn)

    s = sub.add_parser("reply", help="operator: interactive reply, no editor")
    s.add_argument("id", nargs="?")
    s.set_defaults(fn=cmd_reply)

    s = sub.add_parser("answer", help="operator: answer non-interactively")
    s.add_argument("id")
    s.add_argument("text")
    s.set_defaults(fn=cmd_answer)

    return ap.parse_args().fn(ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())

# KNOWN DEFECTS -- all deliberate, this is a PoC (see poc020 ## result):
#   - No silent-deadlock detection. An agent that ends its turn without
#     re-asking leaves an empty inbox that reads as "finished".
#   - No retention or pruning. adr0013 requires an age cap; these files quote
#     whatever the agent had in context.
#   - Idempotency matches on question text, so two agents asking the identical
#     question collide on one file.
#   - slug() truncates at 48 chars and loses the meaningful tail.
#   - No handling for a store that vanishes mid-wait beyond exit 3.
#   - mtime polling assumes the editor writes in place; an editor whose
#     write-then-rename changes the inode is untested.
