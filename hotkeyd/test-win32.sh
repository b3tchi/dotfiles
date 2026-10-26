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
#   ./cmd/hotkeyd:_Windows_    the control socket against a running daemon
#   ./internal/win32           the key translator, cross-checked against
#                              VkKeyScanEx/MapVirtualKeyEx on the US layout
#                              (00000409) the session already has loaded
#
# Containment. Every test binary runs with %LOCALAPPDATA% and %USERPROFILE%
# pointed into the scratch directory (passed through WSLENV), so nothing a
# test writes can reach the real %LOCALAPPDATA%\hotkeyd. The only processes
# the tests end are their own children, by handle; every helper they start
# exits on its own within a minute. The scratch directory is removed at the
# end unless KEEP=1.
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
    if env -C "$scratch" "$exe" "${args[@]}"; then
        echo "== $pkg: PASS"
    else
        echo "== $pkg: FAIL"
        failed+=("$pkg")
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    echo "test-win32.sh: FAILED: ${failed[*]}"
    exit 1
fi
echo "test-win32.sh: all passed ($#)"
