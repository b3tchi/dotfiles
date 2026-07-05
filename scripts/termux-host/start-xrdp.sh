#!/data/data/com.termux/files/usr/bin/bash
# Termux remote desktop: Xvnc (:1, i3) bridged by xrdp.
# Connect an RDP client to 127.0.0.1:3389 and enter your VNC password
# (~/.vnc/passwd, set via `vncpasswd`; default here is "termux").
set -u

: "${PREFIX:=/data/data/com.termux/files/usr}"
export PREFIX
export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$PREFIX/bin:$PATH"
export TMPDIR="$PREFIX/tmp"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export XDG_RUNTIME_DIR="$TMPDIR/runtime-$(id -u)"
# Termux has no /bin/sh; terminals need a real shell or they exit instantly.
export SHELL="$PREFIX/bin/bash"

DISP=2                 # X display :2  -> VNC/TCP 5902 (matches xrdp.ini)
RFBPORT=5902
GEOM="1280x720"
DEPTH=24

mkdir -p "$PREFIX/var/run/xrdp" "$TMPDIR/.X11-unix" /tmp/.X11-unix \
         "$XDG_RUNTIME_DIR" "$HOME/.vnc"
chmod 1777 "$TMPDIR/.X11-unix" /tmp/.X11-unix 2>/dev/null || true

if [ ! -f "$HOME/.vnc/passwd" ]; then
  echo "!! No ~/.vnc/passwd - create one:  vncpasswd" >&2; exit 1
fi

# --- stop previous instances (use -x / display file, never 'pkill -f Xvnc') ---
pkill -x xrdp 2>/dev/null || true
pkill -x xrdp-sesman 2>/dev/null || true
for pid in $(ps -e 2>/dev/null | grep -i '[X]vnc' | awk '{print $1}'); do kill -9 "$pid" 2>/dev/null || true; done
rm -f "/tmp/.X${DISP}-lock" "/tmp/.X11-unix/X${DISP}" \
      "$TMPDIR/.X${DISP}-lock" "$TMPDIR/.X11-unix/X${DISP}" 2>/dev/null || true
sleep 1

# --- start Xvnc :DISP (localhost only, no X11 TCP, VNC-password auth) ---
echo ">> starting Xvnc :$DISP ..."
setsid Xvnc ":$DISP" -localhost -nolisten tcp -rfbport "$RFBPORT" \
  -rfbauth "$HOME/.vnc/passwd" -geometry "$GEOM" -depth "$DEPTH" \
  -SecurityTypes VncAuth </dev/null >"$HOME/.vnc/Xvnc.log" 2>&1 &
sleep 3

# --- launch i3 on that display ---
echo ">> starting i3 on :$DISP ..."
setsid env DISPLAY=":$DISP" dbus-launch --exit-with-session i3 \
  </dev/null >"$HOME/.vnc/i3.log" 2>&1 &
sleep 1

# --- start xrdp bridge (RDP 3389 -> VNC 5901); no sesman auth involved ---
echo ">> starting xrdp ..."
xrdp >/dev/null 2>&1 || true
sleep 2

echo
echo ">> processes:"; ps -e 2>/dev/null | grep -iE '[X]vnc|[x]rdp|[i]3' || echo "   (none - see logs)"
echo ">> Xvnc.log tail:"; tail -n 4 "$HOME/.vnc/Xvnc.log" 2>/dev/null
echo
echo ">> Ready. RDP -> 127.0.0.1:3389   password: your VNC password (default 'termux')"
