#!/usr/bin/env bash
# test-win32.sh - run hotkeyd's Go tests as WINDOWS test binaries, from WSL.
#
#   hotkeyd/test-win32.sh [PKG[:RUN[:SKIP]]]...
#
# Each PKG is cross-compiled with GOOS=windows `go test -c`, copied into a
# private scratch directory under the Windows %TEMP% (a Windows image is
# never run from the \\wsl.localhost share), and run there through WSL
# interop with -test.v. RUN and SKIP, when given, are passed as -test.run
# and -test.skip. With no arguments the default set is:
#
#   ./internal/proc            spawn, lock and paths on Windows, and the
#                              package's portable tests. grabreport_test.go
#                              is skipped: it points $XDG_RUNTIME_DIR, which
#                              the Windows build does not read, and its
#                              atomic-rename test fails on Windows
#                              (kwi3-f9i4, which lifts this skip)
#   ./cmd/hotkeyd:_Windows_    the control socket against a running daemon,
#                              --health with each check failing in turn and
#                              `recover` and `stop` against a dry-run daemon
#                              process (kwi3-hoex.30),
#                              and `--input win32` assembled: a WM_HOTKEY
#                              posted to the daemon's window dispatches
#                              (DryRun - nothing is registered)
#   ./internal/win32           the key translator, cross-checked against
#                              VkKeyScanEx/MapVirtualKeyEx on the US layout
#                              (00000409) the session already has loaded;
#                              the RegisterHotKey thread, which registers
#                              ONLY Ctrl+Alt+Shift+F22/F23 (registrations
#                              are window-station wide, kwi3-hoex.8)
#                              and the low-level hook's thread and procedure
#                              (sp012 Task 5), the procedure called directly
#                              and SetWindowsHookEx replaced by a recorder:
#                              NO real WH_KEYBOARD_LL hook is ever installed
#                              (it would see Jan's keys); the real installer
#                              refuses inside a test binary
#
# GOFLAGS=-tags=win32 builds the binaries with the Windows table.
# TestWin32Run_Windows_E2E_HostFocusesWorkspace2 needs a running
# i3kwin-win32 on a rig desktop, named by HOTKEYD_E2E_PIPE (and the binary
# started ON that desktop); without it, it skips.
#
# Containment. Every test binary runs with %LOCALAPPDATA% and %USERPROFILE%
# pointed into the scratch directory (passed through WSLENV), so nothing a
# test writes can reach the real %LOCALAPPDATA%\hotkeyd. The only processes
# the tests end are their own children, by handle; every helper they start
# exits on its own within a minute. The scratch directory is removed at the
# end unless KEEP=1.
#
# Logs (kwi3-hoex.31). Each package's -test.v output goes to the terminal
# AND to a log. A package that fails keeps its log OUTSIDE the scratch
# directory, as <date>-<pid>/<pkg>.log under $HOTKEYD_TEST_LOGDIR (default
# ~/.cache/hotkeyd-test-win32, $XDG_CACHE_HOME honoured), so it survives
# the cleanup and a caller that piped the run through `tail`. The script
# then prints a `kept log:` line naming it and the `--- FAIL` lines it
# holds. A passing package's log goes with the scratch directory.
#
# Exit status: 0 when every package passed, 1 when any failed, 2 on a usage
# or setup error (no Go, no Windows interop, a build that failed).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "test-win32.sh: $*" >&2; exit 2; }

command -v go >/dev/null || die "no go on PATH"
command -v wslpath >/dev/null || die "not WSL (no wslpath)"
[ -x /mnt/c/Windows/System32/cmd.exe ] || die "no Windows interop (/mnt/c/Windows/System32/cmd.exe)"

if [ $# -eq 0 ]; then
    set -- "./internal/proc::^Test(WriteGrabReport|ReadGrabReport|CurrentGrabReport|AtomicWriteFile)" ./cmd/hotkeyd:_Windows_ ./internal/win32
fi

wintemp="$(env -C /mnt/c /mnt/c/Windows/System32/cmd.exe /d /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')"
[ -n "$wintemp" ] || die "cannot read the Windows %TEMP%"
scratch_win="$wintemp\\hotkeyd-test-$$"
scratch="$(wslpath -u "$scratch_win")"
mkdir -p "$scratch/localappdata" "$scratch/home" || die "cannot create $scratch"
cleanup() {
    if [ "${KEEP:-}" = 1 ]; then
        echo "test-win32.sh: kept $scratch_win"
    else
        rm -rf "$scratch" 2>/dev/null || echo "test-win32.sh: could not remove $scratch_win (a helper still exiting?)" >&2
    fi
}
trap cleanup EXIT

export LOCALAPPDATA="$scratch_win\\localappdata"
export USERPROFILE="$scratch_win\\home"
export WSLENV="LOCALAPPDATA:USERPROFILE${WSLENV:+:$WSLENV}"

logdir="${HOTKEYD_TEST_LOGDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/hotkeyd-test-win32}/$(date +%Y%m%d-%H%M%S)-$$"

# keep_log PKG LOG: copy a failing package's log out of the scratch dir.
keep_log() {
    local name kept
    name="$(basename "$2")"
    if ! mkdir -p "$logdir" || ! cp "$2" "$logdir/$name"; then
        echo "test-win32.sh: could not keep the log of $1 in $logdir" >&2
        return
    fi
    kept="$logdir/$name"
    echo "test-win32.sh: kept log: $kept"
    grep -E -e '^[[:space:]]*--- FAIL' -e '^panic:' -e '^\*\*\* Test killed' "$kept" | sed 's/^/test-win32.sh:   /'
}

failed=()
for spec in "$@"; do
    pkg="${spec%%:*}"
    run="" skip=""
    if [ "$spec" != "$pkg" ]; then
        rest="${spec#*:}"
        run="${rest%%:*}"
        [ "$rest" != "$run" ] && skip="${rest#*:}"
    fi
    name="$(echo "$pkg" | tr -c 'A-Za-z0-9\n' '_')"
    exe="$scratch/$name.test.exe"
    echo "== $pkg${run:+ (-run $run)}${skip:+ (-skip $skip)}"
    if ! GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go -C "$HERE" test -c -o "$exe" "$pkg"; then
        die "build of $pkg for Windows failed"
    fi
    args=(-test.v -test.count=1)
    [ -n "$run" ] && args+=(-test.run "$run")
    [ -n "$skip" ] && args+=(-test.skip "$skip")
    log="$scratch/$name.log"
    env -C "$scratch" "$exe" "${args[@]}" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 0 ]; then
        echo "== $pkg: PASS"
    else
        echo "== $pkg: FAIL (exit $rc)"
        keep_log "$pkg" "$log"
        failed+=("$pkg")
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    echo "test-win32.sh: FAILED: ${failed[*]}"
    exit 1
fi
echo "test-win32.sh: all passed ($#)"
