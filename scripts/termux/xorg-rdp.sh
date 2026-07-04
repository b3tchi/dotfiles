#!/data/data/com.termux/files/usr/bin/bash
# Termux-side manager for the native-RDP proot stack.
#   xorg-rdp.sh start | stop | status | log
#
# Runs the whole root stack (dbus + xrdp-sesman + xrdp + Xorg/xorgxrdp + i3)
# inside proot Arch as root, and holds the proot instance alive in the
# background so the daemons survive (a `proot-distro login -- cmd` tears its
# process tree down the moment cmd returns, which would kill the daemons).
#
# The holder is a supervisor loop (not bare `sleep infinity`): the stack starts
# a persistent tmux base session ('local', as jan) that lives in THIS proot
# instance. `stop` keeps the holder+tmux alive and only drops the RDP daemons;
# `start` then re-runs the stack inside the SAME instance via /tmp/.rdp-restart
# (so terminals share the tmux server's proot — cross-instance attach fails
# "access not allowed"). `stop --all` drops the holder and kills tmux.
#
# RDP client -> 127.0.0.1:3389 , login: jan / <unix password>.
# Tip: run `termux-wake-lock` first so Android doesn't sleep-kill it.
set -u

DISTRO=archlinux
PROOT_SCRIPT=/home/jan/.dotfiles/scripts/termux/start-xorg-rdp-proot.sh
PIDFILE="$HOME/.xorg-rdp.pid"
LOG="$HOME/.xorg-rdp.log"

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

case "${1:-start}" in
  start)
    if is_running; then
      # Holder already up (e.g. after a plain `stop` that kept tmux). Restart
      # ONLY the RDP daemons, INSIDE this same proot instance, via the restart
      # flag the supervisor loop watches — so i3/terminals stay in the same
      # proot as the persistent tmux server (a tmux server in a different proot
      # instance rejects clients with "access not allowed").
      echo ">> holder already running (pid $(cat "$PIDFILE")); signalling RDP restart ..."
      proot-distro login "$DISTRO" -- bash -lc 'touch /tmp/.rdp-restart' 2>/dev/null || true
      sleep 6
      echo ">> log tail:"; tail -n 8 "$LOG" 2>/dev/null
      echo ">> RDP -> 127.0.0.1:3389  (tmux preserved)"
      exit 0
    fi
    # Fresh holder: run the stack once, then a supervisor loop that keeps the
    # proot instance (and its tmux server) alive and re-runs the stack whenever
    # /tmp/.rdp-restart appears (touched by `start` while the holder is up).
    setsid nohup proot-distro login "$DISTRO" -- \
      bash -lc "bash '$PROOT_SCRIPT'; while true; do sleep 3; [ -f /tmp/.rdp-restart ] && { rm -f /tmp/.rdp-restart; bash '$PROOT_SCRIPT'; }; done" \
      >"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    echo ">> starting... (pid $!)"
    sleep 6
    echo ">> log tail:"; tail -n 8 "$LOG" 2>/dev/null
    echo ">> RDP -> 127.0.0.1:3389  (jan / unix password).  logs: $LOG  and inside proot /var/log/xrdp*.log"
    ;;
  stop)
    full=0
    case "${2:-}" in --all|-a) full=1;; esac
    # Always stop the RDP display daemons (the session). xrdp-chansrv is reaped
    # too — one spawns per connect and they orphan on disconnect, piling up.
    proot-distro login "$DISTRO" -- \
      bash -lc 'pkill -x xrdp 2>/dev/null; pkill -x xrdp-sesman 2>/dev/null; pkill -x Xorg 2>/dev/null; pkill -x i3 2>/dev/null; pkill -x xrdp-chansrv 2>/dev/null; true' 2>/dev/null || true
    if [ "$full" = 1 ]; then
      # --all: drop the proot holder too -> kills the persistent tmux server.
      if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
      echo ">> stopped (full: RDP + proot holder + tmux)"
    else
      # default: keep the holder (and its tmux server) alive; `start` reattaches
      # the RDP daemons into it. Use `stop --all` to kill tmux too.
      echo ">> stopped RDP (tmux kept alive; 'stop --all' kills it)"
    fi
    ;;
  status)
    if is_running; then echo "running (pid $(cat "$PIDFILE"))"; else echo "not running"; fi
    proot-distro login "$DISTRO" -- \
      bash -lc 'echo "proot procs:"; pgrep -a xrdp-sesman; pgrep -a xrdp; pgrep -x Xorg; pgrep -x i3' 2>/dev/null || true
    ;;
  log)  tail -n 40 "$LOG" 2>/dev/null || echo "no log yet";;
  *) echo "usage: $0 {start | stop [--all] | status | log}"; echo "       stop keeps tmux alive; stop --all kills the proot holder + tmux"; exit 1;;
esac
