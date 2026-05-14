#!/data/data/com.termux/files/usr/bin/bash
# Build qs-stats-daemon for Termux. Run on Termux side (not inside proot).
# Output: $PREFIX/bin/qs-stats-daemon
#
# Prereq: pkg install clang  (or gcc)

set -e

SRC="$(cd "$(dirname "$0")" && pwd)/qs-stats-daemon.c"
OUT="${PREFIX:-/data/data/com.termux/files/usr}/bin/qs-stats-daemon"
CC="${CC:-clang}"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "Error: $CC not found. Run: pkg install clang"
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "Error: source not found: $SRC"
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
"$CC" -O2 -Wall -Wextra -o "$OUT" "$SRC"
echo "Built: $OUT"
"$OUT" --help 2>/dev/null || true
