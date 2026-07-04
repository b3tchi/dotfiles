#!/data/data/com.termux/files/usr/bin/bash
# Termux-side manager for the native-RDP proot stack.
#   xorg-rdp.sh start | stop | status | log
#
# Runs the whole root stack (dbus + xrdp-sesman + xrdp + Xorg/xorgxrdp + i3)
# inside proot Arch as root, and holds the proot instance alive in the
# background so the daemons survive (a `proot-distro login -- cmd` tears its
# process tree down the moment cmd returns, which would kill the daemons).
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
    if is_running; then echo "already running (pid $(cat "$PIDFILE"))"; exit 0; fi
    # Hold proot open with `sleep infinity` after the stack is up.
    setsid nohup proot-distro login "$DISTRO" -- \
      bash -lc "bash '$PROOT_SCRIPT'; exec sleep infinity" \
      >"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    echo ">> starting... (pid $!)"
    sleep 6
    echo ">> log tail:"; tail -n 8 "$LOG" 2>/dev/null
    echo ">> RDP -> 127.0.0.1:3389  (jan / unix password).  logs: $LOG  and inside proot /var/log/xrdp*.log"
    ;;
  stop)
    # kill daemons inside proot, then drop the keep-alive proot instance
    proot-distro login "$DISTRO" -- \
      bash -lc 'pkill -x xrdp 2>/dev/null; pkill -x xrdp-sesman 2>/dev/null; pkill -x Xorg 2>/dev/null; pkill -x i3 2>/dev/null; true' 2>/dev/null || true
    if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
    echo ">> stopped"
    ;;
  status)
    if is_running; then echo "running (pid $(cat "$PIDFILE"))"; else echo "not running"; fi
    proot-distro login "$DISTRO" -- \
      bash -lc 'echo "proot procs:"; pgrep -a xrdp-sesman; pgrep -a xrdp; pgrep -x Xorg; pgrep -x i3' 2>/dev/null || true
    ;;
  log)  tail -n 40 "$LOG" 2>/dev/null || echo "no log yet";;
  *) echo "usage: $0 {start|stop|status|log}"; exit 1;;
esac
