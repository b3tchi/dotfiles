#!/usr/bin/env bash
# kwi3-titlebar.sh - fit Windows' titlebar to kwi3's module, from WSL
# (kwi3-9mcs): a captioned window's titlebar + top frame becomes exactly one
# module row of kwi3's config.js (21 px at module 8x21), so a window kwi3
# tiles into a slot of whole modules keeps its client on the grid.
#
#   winmetrics/kwi3-titlebar.sh [--config <config.js>] [--dry-run]
#   winmetrics/kwi3-titlebar.sh --restore [--dry-run]
#
# It sets four NONCLIENTMETRICS fields - iBorderWidth 1, iCaptionHeight
# module height - 5, iPaddedBorderWidth 0 and the caption font's lfHeight
# (Windows' own -12, or the biggest smaller size whose caption floor fits) -
# with SystemParametersInfo(SPI_SETNONCLIENTMETRICS, SPIF_UPDATEINIFILE |
# SPIF_SENDCHANGE): live in every window and kept across logons
# (HKCU\Control Panel\Desktop\WindowMetrics). It is machine-wide for this
# Windows user, not kwi3's alone. kwi3-titlebar.js has the geometry, what of
# it is measured and what derived; ncm.ps1 reads and writes the metrics.
# --restore puts Windows 11's defaults back: border 1, caption 22, padded 4,
# caption font -12 (registry -15/-330/-60).
#
# The module comes from kwi3's config.js RUN with kwi3.host "win32" by
# winterm/kwi3-fragment.js - the same run that gives Windows Terminal its
# cell (winterm/install-kwi3-fragment.sh): by default the file the Windows
# host loads, %KWI3_CONFIG%, else %APPDATA%\kwi3\config.js; --config names
# another (a Linux or Windows path). A change to module there takes a re-run.
#
# Prints the metrics before, the target and - when it applied them - after.
# Idempotent: when the metrics already are the target it says "no change"
# and writes nothing. --dry-run reads, prints, and writes nothing.
# Measured and derived at 96 dpi only; any other system dpi is refused.
#
# $KWI3_TITLEBAR_NCM, when set, is run instead of ncm.ps1 (same verbs:
# `read`, `set <b>,<c>,<p>,<f>`), so the flow can be driven without touching
# the real metrics.
#
# Exit: 0 applied or unchanged; 1 not derivable, or Windows did not take the
# values; 2 refused (no config.js, dpi, a usage or setup error).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ME=kwi3-titlebar.sh

die() { echo "$ME: $*" >&2; exit "${2:-2}"; }
die1() { echo "$ME: $*" >&2; exit 1; }

config=""
dry=0
restore=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ $# -ge 2 ] || die "--config needs a path"; config="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        --restore) restore=1; shift ;;
        -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ "$restore" = 1 ] && [ -n "$config" ] && die "--restore takes no --config"

command -v node >/dev/null || die "no node on PATH"
command -v wslpath >/dev/null || die "not WSL (no wslpath)"
CMD=/mnt/c/Windows/System32/cmd.exe
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[ -x "$CMD" ] || die "no Windows interop ($CMD)"

ncm() {
    if [ -n "${KWI3_TITLEBAR_NCM:-}" ]; then
        "$KWI3_TITLEBAR_NCM" "$@"
    else
        env -C /mnt/c "$PS" -NoProfile -ExecutionPolicy Bypass \
            -File "$(wslpath -w "$HERE/ncm.ps1")" "$@" | tr -d '\r'
    fi
}

winenv() {  # winenv NAME -> the Windows value, empty when unset
    local v
    v="$(env -C /mnt/c "$CMD" /d /c "echo %$1%" 2>/dev/null | tr -d '\r')"
    [ "$v" = "%$1%" ] && v=""
    printf '%s' "$v"
}

topath() {  # a Linux path, or a Windows one mapped into WSL
    case "$1" in
        [A-Za-z]:\\*|[A-Za-z]:/*|\\\\*) wslpath -u "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

plan_args=(--restore)
if [ "$restore" = 0 ]; then
    if [ -z "$config" ]; then
        config="$(winenv KWI3_CONFIG)"
        if [ -z "$config" ]; then
            ad="$(winenv APPDATA)"
            [ -n "$ad" ] || die "cannot read %APPDATA% from Windows"
            config="$ad\\kwi3\\config.js"
        fi
    fi
    config_l="$(topath "$config")" || die "cannot map $config into WSL"
    [ -f "$config_l" ] || die "REFUSED - no kwi3 config.js at $config (the Windows host's %KWI3_CONFIG%, else %APPDATA%\\kwi3\\config.js); name one with --config"
    plan_args=(--config "$config_l" --source "$config")
fi

tmp="$(mktemp -d)" || die "cannot make a temp dir"
trap 'rm -rf "$tmp"' EXIT

ncm read >"$tmp/before.json" || die1 "cannot read the metrics (ncm.ps1 read)"
node "$HERE/kwi3-titlebar.js" plan --metrics "$tmp/before.json" "${plan_args[@]}" >"$tmp/plan" 2>"$tmp/plan.err"
rc=$?
if [ "$rc" != 0 ]; then
    sed "s/^kwi3-titlebar: /$ME: /" "$tmp/plan.err" >&2
    case "$(cat "$tmp/plan.err")" in *"dpi"*) exit 2 ;; esac
    exit "$rc"
fi
grep -E '^(before|target):' "$tmp/plan"
want="$(sed -n 's/^values: //p' "$tmp/plan")"
change="$(sed -n 's/^change: //p' "$tmp/plan")"

if [ "$change" = no ]; then
    echo "$ME: no change - the metrics already are the target"
    exit 0
fi
if [ "$dry" = 1 ]; then
    echo "$ME: --dry-run - would set border,caption,padded,font = $want; nothing written"
    exit 0
fi

ncm set "$want" || die1 "SPI_SETNONCLIENTMETRICS refused $want (ncm.ps1 set)"
ncm read >"$tmp/after.json" || die1 "cannot read the metrics back (ncm.ps1 read)"
echo "after:  $(node "$HERE/kwi3-titlebar.js" describe --metrics "$tmp/after.json")"
check="$(node -e '
const t = require(process.argv[1]);
const m = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const [border, caption, padded, font] = process.argv[3].split(",").map(Number);
const want = t.inset({ border, caption, padded, font });
if (t.values(m) !== process.argv[3]) console.log("Windows took " + t.values(m) + ", not " + process.argv[3]);
else if (m.inset !== want) console.log("titlebar + top frame is " + m.inset + " px, not the " + want + " px worked out");
' "$HERE/kwi3-titlebar.js" "$tmp/after.json" "$want")"
[ -z "$check" ] || die1 "$check - the caption floor or a minimum differs from what kwi3-titlebar.js assumes"
echo "$ME: set border,caption,padded,font = $want"
