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
been copied by then. It never ends a process. Stop the daemon first with
`hotkeyd.exe stop` (below), then install, then run `hotkeyd recover` to
start the new image with the old daemon's arguments. A
`LOCALAPPDATA=<dir> APPDATA=<dir2> WSLENV=LOCALAPPDATA:APPDATA` prefix
installs under those directories instead of the real profile.

Per-desktop files live in `%LOCALAPPDATA%\hotkeyd\`, named after the desktop:

- `<desktop>.lock`: pid and heartbeat.
- `<desktop>.sock`: the control socket.
- `<desktop>.args`: the daemon's arguments, for `recover`.
- `<desktop>.log`: the stderr of a daemon `recover` started (the previous
  one is kept as `.log.1`).

### `stop`

```
"%LOCALAPPDATA%\hotkeyd\bin\hotkeyd.exe" stop [--display DESKTOP]
```

Stops this desktop's daemon (kwi3-hoex.30); `--display` names another
desktop's. It sends `{"stop":true}` on the control socket, and the daemon
shuts down as on SIGTERM: every chord unregistered, the low-level hook
removed, the control and state sockets closed, the lock released and its
file emptied, so the next start has no stale pid to take over. If the daemon
has not exited 5 s later, or its control socket does not answer, `stop` ends
it **by pid**: `TerminateProcess` on a handle opened on the lock's pid
before the request, and only when that process runs `hotkeyd.exe` (or the
very binary running `stop`). A pid running anything else is refused and
left alone. Nothing is ever ended by name. No key-up is sent: the hook
passes every modifier, so a stopped daemon strands none.

Exit codes: 0 when the daemon stopped, and 0 with `not running` when none
holds the lock (the state asked for already holds, so a script can run
`stop` unconditionally); 1 when it could not be stopped, saying why (the
pid cannot be opened, is not hotkeyd, or survives `TerminateProcess`); 2 on
a usage error.

`taskkill /F /PID <pid>` stays the fallback when `stop` itself cannot run.
Plain `taskkill /PID` reports SUCCESS and leaves the daemon running
(measured, kwi3-hoex.18): its windows are message-only, so a polite
`taskkill` has nothing to close. After `/F` the next start takes the stale
lock over and says so.

### `--input win32`

```
"%LOCALAPPDATA%\hotkeyd\bin\hotkeyd.exe" --input win32
```

The Windows key source (sp012). `win32` is also the default input of a
Windows build. What it does, from the code:

- **`$mod` is Alt** (Mod1). Windows keys become X11 keysyms and modifier
  bits in `internal/win32`, so everything after that is the X11 code path:
  layers, hold layers, `mode.set`.
- **Plain chords are `RegisterHotKey`** (`MOD_NOREPEAT`) on one thread with
  its own message-only window. A layer change re-registers only what
  differs. The grab report names each refused chord with Windows' error.
  1409 means another program holds it, and registrations are shared by
  every desktop of the window station.
- **A `WH_KEYBOARD_LL` hook is installed only because of the `$mod+Tab`
  switcher**, which needs key releases. Its callback only queues. It
  swallows the keys the active layer owns, decides each key once from its
  press to its release, and never swallows the recover chord. Alt+Tab over
  RDP reaches it only with `keyboardhook:i:1` in the `.rdp`.
- **The table** is `config.go` built with `-tags win32`, and
  `cmd/hotkeyd/host_win32.go` changes what differs on Windows:
  - `$mod+Return` runs `wt.exe -w new`.
  - `$mod+d` and the `switcher` layer run `kwi3-run.exe <verb>` (see
    below).
  - `$mod+1..8` (`Ctrl`/`Shift` to move) go straight to workspace RPC.
  - `$mod+s`/`$mod+b` split with no notification.
  - The Linux-only chords are removed: screenshots, `$mod+n`, `$mod+v`,
    `$mod+0`, `$mod+Shift+c`, `$mod+p`, `$mod+9`, `$mod+Ctrl+m` and
    `$mod+Shift+e`.

  `install-win32.sh` passes the tag. An untagged Windows build carries the
  Linux table.
- **kwi3** is `$KWI3SOCK`. Unset, it is the host's own pipe,
  `\\.\pipe\kwi3-<%USERNAME%>-<desktop>`. The log says so, and the pipe
  must match the host's `rpc socket on ...` line.
- **The recover chord `$mod+Shift+r` is the host's.** `bind.ReservedChords`
  keeps it out of every registration and the hook passes it, so the host's
  own `RegisterHotKey` gets it.

**Start it after the host.** The kwi3 host `i3kwin-win32` starts first. Once
it has printed `i3kwin-win32: rpc socket on \\.\pipe\kwi3-<user>-<desktop>`,
start hotkeyd on the same desktop. kwi3's `AGENTS.md` (Windows host) has the
exact commands. Its startup lines say how many chords were registered
(`<n> of <m> chords registered via RegisterHotKey on desktop <name>
($mod=Mod1) ...`) and whether the hook went in.

Started from WSL, hotkeyd lands in WSL's one kill-on-close job, together
with the host and every program a chord starts. `wsl --shutdown` or the WSL
VM stopping kills all of them. Closing the terminal does not (kwi3-hoex.29;
kwi3's `AGENTS.md` has the recovery).

Two environment variables are for tests and rigs only:

- `HOTKEYD_WIN32_DRYRUN=1` registers no chord and installs no hook. Only a
  `WM_HOTKEY` posted to its window is served.
- `HOTKEYD_WIN32_DEBUG=1` logs every `LLKHF_INJECTED` key the hook queues.

**What is proven, and what is not.** The translator, the table, the hook's
decisions, dispatch and `recover` are covered by the Go tests (below). A
`WM_HOTKEY` posted to a dry-run daemon on a kwi3 rig desktop made the host
focus workspace 2 (`TestWin32Run_Windows_E2E_HostFocusesWorkspace2`).
That proves dispatch, not that a key reaches it. Windows delivers hotkeys
and the hook only on the input desktop. So key delivery over RDP is still
**attended-only**, pending kwi3-hoex.14 and kwi3-hoex.17. That covers:

- the chords and the switcher on real keys;
- whether the Alt release opens an application's menu bar;
- `LLKHF_INJECTED`;
- the Dvorak/US layout. Jan's session has both loaded, and the translator
  assumes US.

Windows Terminal for `$mod+Return` is not installed yet (kwi3-hoex.16). Jan
saw it work live on 2026-10-27: `Alt+d` opened the launcher on his session.
That was not yet the kwi3-hoex.17 acceptance.

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

The host runs `recover` from its recover chord (`$mod+Shift+r`, the host's
own `RegisterHotKey`) and waits 15 s for it. A
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
   the stop, and only when that process runs `hotkeyd.exe` (the same rule
   and code as `stop`). That is logged. With no daemon running there is
   nothing to stop.
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
those tests runs dry, against a pipe the test serves itself. With no
arguments it runs the default set. `GOFLAGS=-tags=win32` builds the
binaries with the Windows table. The script's header lists what each
package covers. No test registers a chord anyone types: the
`RegisterHotKey` test uses only Ctrl+Alt+Shift+F22/F23. No test installs a
real `WH_KEYBOARD_LL` hook either, and the real installer refuses inside a
test binary.
