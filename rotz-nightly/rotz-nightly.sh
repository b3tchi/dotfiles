#!/bin/sh
# rotz-nightly.sh -- run `rotz install` unattended, then report the outcome as
# a desktop notification through the ft010 notification stack.
#
# WHAT IT IS
#
#   The body of rotz-nightly.service (timer: rotz-nightly.timer). One run =
#   one `rotz install`, one log file, exactly one notification -- success or
#   failure, never silence. A nightly job nobody hears from is a nightly job
#   nobody notices has been broken for three weeks.
#
# THE NOTIFICATION -- ft010, NOT A POPUP
#
#   `notify-send` on the user session bus, which the single `quickshell -p
#   notif` daemon owns (adr0012). The daemon appends the entry to the
#   persistent history store and bumps the live state file, so every bar in
#   every session tickers it and the bell counts it; `$mod+Shift+n` recalls it
#   hours later. No popup window is involved -- ft010 has none by design.
#
#   Urgency IS the verdict: `normal` on exit 0, `critical` on anything else
#   (critical is what turns the bell red on the bars).
#
#   The call is wrapped in `timeout` (NOTIFY_TIMEOUT, default 5s). If no
#   daemon owns the name, notify-send can sit on the bus waiting for an
#   activatable service that never arrives; a nightly job must not hang on
#   its own epilogue. A lost notification is logged, never fatal -- the log
#   file is the durable record, the notification is the doorbell.
#
# THE BUS -- DERIVED, NOT INHERITED
#
#   Under `systemd --user` the manager environment normally carries
#   DBUS_SESSION_BUS_ADDRESS already. When it does not (a manager started
#   before the bus, a hand-run invocation from cron), the socket is still at
#   the well-known $XDG_RUNTIME_DIR/bus, so it is recomputed rather than
#   guessed at -- the same posture qs-notif.sh takes with the session it
#   talks to.
#
# SUDO -- CHECKED FIRST, NEVER GAMBLED ON
#
#   Most dot.yaml `installs.cmd` bodies shell out to `sudo pacman`. There is
#   no tty and no askpass under a timer, so a password-requiring sudo turns
#   the whole run into a pile of prompts failing one package at a time. The
#   run is therefore GATED on `sudo -n true`: no passwordless sudo means the
#   install is skipped up front and the notification says exactly that,
#   instead of a 40-line partial failure. Set ROTZ_NIGHTLY_SUDO_CHECK=0 to
#   run anyway (packages that need no root still install fine).
#
# ENV KNOBS
#   ROTZ_NIGHTLY_TARGET      dots to install; empty (default) = all
#   ROTZ_NIGHTLY_LOG_DIR     default ${XDG_STATE_HOME:-~/.local/state}/rotz-nightly
#   ROTZ_NIGHTLY_SUDO_CHECK  1 (default) gate on `sudo -n true`, 0 skip gate
#   ROTZ_NIGHTLY_NOTIFY_TIMEOUT  seconds notify-send may take, default 5
#
# EXIT CODES
#   0  install succeeded (or nothing to do)
#   1  install failed, or skipped because sudo would have prompted
#  78  XDG_* / HOME unset -- refusing to guess a log location (EX_CONFIG)
set -u

PROG="${0##*/}"
APP=rotz-nightly

TARGET="${ROTZ_NIGHTLY_TARGET:-}"
SUDO_CHECK="${ROTZ_NIGHTLY_SUDO_CHECK:-1}"
NOTIFY_TIMEOUT="${ROTZ_NIGHTLY_NOTIFY_TIMEOUT:-5}"

case "$NOTIFY_TIMEOUT" in '' | *[!0-9]*)
  printf '%s: ROTZ_NIGHTLY_NOTIFY_TIMEOUT must be a number, got "%s"\n' "$PROG" "$NOTIFY_TIMEOUT" >&2
  exit 1 ;;
esac

# ------------------------------------------------------------------ paths ---

log_dir() {
  if [ -n "${ROTZ_NIGHTLY_LOG_DIR:-}" ]; then printf '%s\n' "$ROTZ_NIGHTLY_LOG_DIR"; return 0; fi
  if [ -n "${XDG_STATE_HOME:-}" ]; then printf '%s/rotz-nightly\n' "$XDG_STATE_HOME"; return 0; fi
  if [ -n "${HOME:-}" ]; then printf '%s/.local/state/rotz-nightly\n' "$HOME"; return 0; fi
  printf '%s: XDG_STATE_HOME and HOME are both unset; refusing to guess a log location\n' "$PROG" >&2
  return 78
}

LOG_DIR="$(log_dir)" || exit $?
mkdir -p "$LOG_DIR" 2>/dev/null || { printf '%s: cannot create %s\n' "$PROG" "$LOG_DIR" >&2; exit 78; }
LOG="$LOG_DIR/last.log"

# ------------------------------------------------------------------ notify ---
#
# notify <urgency> <summary> <body>. Bounded, best-effort, never fatal: the
# job's verdict is its exit code and the log, not whether the doorbell rang.
notify() {
  command -v notify-send >/dev/null 2>&1 || {
    printf '%s: notify-send not found; notification skipped\n' "$PROG" >&2
    return 0
  }

  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] \
     && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    export DBUS_SESSION_BUS_ADDRESS
  fi

  timeout "$NOTIFY_TIMEOUT" notify-send -a "$APP" -u "$1" "$2" "$3" 2>/dev/null || {
    printf '%s: notification not delivered (no daemon on the session bus?)\n' "$PROG" >&2
    return 0
  }
}

# Human duration for the notification body: "3m41s", "12s", "1h02m".
duration_of() { # <seconds>
  _d="$1"
  if   [ "$_d" -lt 60 ];   then printf '%ss\n' "$_d"
  elif [ "$_d" -lt 3600 ]; then printf '%sm%02ds\n' "$((_d / 60))" "$((_d % 60))"
  else printf '%sh%02dm\n' "$((_d / 3600))" "$(((_d % 3600) / 60))"
  fi
}

# ------------------------------------------------------------------- main ---

command -v rotz >/dev/null 2>&1 || {
  notify critical "rotz install failed" "rotz not found in PATH"
  printf '%s: rotz not found in PATH\n' "$PROG" >&2
  exit 1
}

if [ "$SUDO_CHECK" = 1 ] && ! sudo -n true 2>/dev/null; then
  notify critical "rotz install skipped" \
    "sudo would prompt for a password -- an unattended timer cannot answer it. See rotz-nightly.sh (SUDO)."
  printf '%s: sudo -n unavailable; skipping the install\n' "$PROG" >&2
  exit 1
fi

START="$(date +%s)"
{
  printf '=== %s  rotz install %s ===\n' "$(date -Is)" "${TARGET:-<all>}"
} > "$LOG"

# Unquoted on purpose: an empty TARGET must expand to NO argument (install
# everything), and a multi-dot target to several words.
# shellcheck disable=SC2086
rotz install $TARGET >> "$LOG" 2>&1
RC=$?
ELAPSED="$(duration_of "$(( $(date +%s) - START ))")"

printf '=== exit %s after %s ===\n' "$RC" "$ELAPSED" >> "$LOG"

if [ "$RC" -eq 0 ]; then
  notify normal "rotz install ok" "${TARGET:-all dots} · $ELAPSED · $LOG"
else
  TAIL="$(grep -iE 'error|failed|warning' "$LOG" | tail -3)"
  [ -n "$TAIL" ] || TAIL="$(tail -3 "$LOG")"
  notify critical "rotz install FAILED (exit $RC)" "${TARGET:-all dots} · $ELAPSED · $LOG
$TAIL"
fi

exit "$RC"
