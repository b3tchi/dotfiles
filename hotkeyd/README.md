# hotkeyd

The keybinding daemon. On X11 it is started and described by `dot.yaml` and
`hotkeyd.sh`; this file covers what is different on **Windows**, where the
kwi3 Win32 host (`i3kwin-win32`, sp012) runs it.

## Windows

### Install

From WSL:

```sh
hotkeyd/install-win32.sh
```

It cross-builds `GOOS=windows -tags win32 -ldflags -H=windowsgui` (the
Windows chord table, no console window), runs the built image's own
`--check`, and copies it to `%LOCALAPPDATA%\hotkeyd\bin\hotkeyd.exe`, the
path the host runs.

It also copies the runner's program list, `kwi3/runner-list.json` in this
checkout, to `%APPDATA%\kwi3\runner-list.json`, where `kwi3-run.exe` reads
it. The list is copied first, before the build and before the check below,
so an edit to it takes a re-run of the script and nothing more. A checkout
without the list is refused before anything is touched.

It **refuses** (exit 2, the daemon not copied) while any process runs from
that path, and names each pid and command line. The runner list has already
been copied by then. It never ends a process. Stop the daemon first, install,
then run `hotkeyd recover` to start the new image. A
`LOCALAPPDATA=<dir> APPDATA=<dir2> WSLENV=LOCALAPPDATA:APPDATA` prefix
installs under those directories instead of the real profile.

Per-desktop files live in `%LOCALAPPDATA%\hotkeyd\`, named after the desktop:

- `<desktop>.lock`: pid and heartbeat.
- `<desktop>.sock`: the control socket.
- `<desktop>.args`: the daemon's arguments, for `recover`.
- `<desktop>.log`: the stderr of a daemon `recover` started (the previous
  one is kept as `.log.1`).

### The runner: which `kwi3-run.exe`

`$mod+d` and the `$mod+Tab` switcher run `kwi3-run.exe <verb>`. kwi3's
`i3kwin/runner/win32/deploy.sh` puts each deploy in a new
`%LOCALAPPDATA%\kwi3\run\v<N>` and names it in
`%LOCALAPPDATA%\kwi3\run\current.txt`; nothing puts it on PATH. So a Run
whose program is the bare word `kwi3-run.exe` starts
`<the directory current.txt names>\kwi3-run.exe`. current.txt is read again
for every start, so the next chord after a deploy uses the new version and
hotkeyd needs no restart. (A runner that is already running keeps its own
version until `kwi3-run.exe quit`: a later start only hands it the verb.)

The first line of current.txt counts. It is an absolute directory, as
deploy.sh writes it, or a name relative to `%LOCALAPPDATA%\kwi3\run`. A BOM,
blanks, the CR and a trailing backslash are ignored.

With no deployed copy (no `%LOCALAPPDATA%`, no current.txt, an empty one, or
one naming a directory or exe that is missing), `kwi3-run.exe` is looked up
on PATH as any other program. The log says which copy was used, or why it
fell back to PATH, once, and again only when that changes. When PATH has
none either, the chord's log line names both places:
`kwi3-run.exe not found: no deployed copy (<why>), and not on PATH: ...`.

### `--health`

```
"%LOCALAPPDATA%\hotkeyd\bin\hotkeyd.exe" --health [--display <desktop>]
```

It checks these in order and names the first that fails:

1. **lock**: the pid in `<desktop>.lock` is running.
2. **control**: the control socket answers a status request, and the answer
   comes from that pid. The run loop answers the request itself, so an
   answer means the loop is turning.
3. **chords**: every chord of the active layer is granted. This is the grab
   report the run loop returns with that answer.
4. **kwi3rpc**: the daemon's kwi3 address (`$KWI3SOCK`, else the host's
   pipe `\\.\pipe\kwi3-<user>-<desktop>`) answers a request.

Exit codes: 0 when it serves, 6 when check 1, 2 or 4 fails, and 9 when check
3 fails.

### `recover`

```
"%LOCALAPPDATA%\hotkeyd\bin\hotkeyd.exe" recover [--display <desktop>]
```

The host runs `recover` from its panic chord and waits 15 s for it. A
non-zero exit makes the host give every window back and exit. `recover` does
four things in order:

1. **Releases stuck modifiers.** For each sided modifier that
   `GetAsyncKeyState` reports held (L/R Shift, Ctrl, Alt, Win), it sends one
   `SendInput` key-up. This is adr0021's second allowed case of synthetic
   input, and it sends nothing else. If no modifier is held, it sends
   nothing.
2. **Stops the running daemon.** It targets the pid in the lock, and only
   while that lock is actually held. It sends `{"stop":true}` on the control
   socket and waits 2 s. If the daemon is still running, `recover` ends it
   **by pid**, never by name: `TerminateProcess` on a handle opened before
   the stop. That is logged. With no daemon running there is nothing to
   stop.
3. **Starts a new daemon** from this executable, detached, with the old
   daemon's arguments and `$KWI3SOCK` / `HOTKEYD_WIN32_DRYRUN` taken from
   `<desktop>.args`.
4. **Waits for `--health`.** It exits 0 once the new pid serves, or 1 if it
   does not, printing the last verdict, which names the check still failing.

All four steps share one 12 s budget, counted from the start of the run, so
`recover` always answers before the host's 15 s timeout. Each step gets what
is left of the budget, up to its own bound: the stop request up to 1 s, each
of the two waits up to 2 s, and each health poll up to 3 s. The last health
poll is cut to whatever remains. A poll cut short can time out on the control
socket while the daemon is still checking kwi3, so if its verdict differs
from the last full-length poll's, `recover` prints both. The worst case is a
daemon that ignores the stop and a new one that never serves. That run uses
1 s + 2 s + 2 s for the stop and about 7 s of health polls, and exits 1 at
12 s.

With `HOTKEYD_WIN32_DRYRUN=1`, `recover` sends no key-up and only says which
keys it would release. A daemon it starts in that mode stays dry.

### Tests

`hotkeyd/test-win32.sh` runs the Windows test binaries with `%LOCALAPPDATA%`
redirected into a scratch directory. Every daemon and every `recover` in
those tests runs dry, against a pipe the test serves itself.
