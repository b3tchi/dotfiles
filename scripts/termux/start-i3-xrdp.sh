#!/bin/bash
# Start i3 (inside proot Arch) on an Xvnc display bridged by xrdp, so the
# proot desktop is reachable over RDP.  Audio via pulseaudio; no GPU accel.
# Usage: bash ~/.dotfiles/scripts/termux/start-i3-xrdp.sh
# Then:  RDP client -> 127.0.0.1:3389   password = your VNC password
#        (~/.vnc/passwd, set via `vncpasswd`; default "termux")
#
# Requires (Termux side): xrdp, tigervnc (Xvnc), pulseaudio, dbus.
# Requires (proot side):  i3, xmodmap, dbus.
set -u

# --- Termux environment -----------------------------------------------------
: "${PREFIX:=/data/data/com.termux/files/usr}"
export PREFIX
export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export TMPDIR="$PREFIX/tmp"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export XDG_RUNTIME_DIR="$TMPDIR/runtime-$(id -u)"
# Termux has no /bin/sh; terminals need a real shell or they exit instantly.
export SHELL="$PREFIX/bin/bash"

DISTRO="archlinux"
USER="jan"
DISP=2                 # X display :2 -> VNC/TCP 5902 (must match xrdp.ini)
RFBPORT=5902
GEOM="1280x720"
DEPTH=24

mkdir -p "$PREFIX/var/run/xrdp" "$TMPDIR/.X11-unix" /tmp/.X11-unix \
         "$XDG_RUNTIME_DIR" "$HOME/.vnc"
chmod 1777 "$TMPDIR/.X11-unix" /tmp/.X11-unix 2>/dev/null || true

if [ ! -f "$HOME/.vnc/passwd" ]; then
  echo "!! No ~/.vnc/passwd - create one:  vncpasswd" >&2
  exit 1
fi

# --- kill previous sessions -------------------------------------------------
# Never 'pkill -f Xvnc' from an inline shell: the pattern matches this argv.
pkill -x xrdp 2>/dev/null || true
pkill -x xrdp-sesman 2>/dev/null || true
pkill -f pulseaudio 2>/dev/null || true
for pid in $(ps -e 2>/dev/null | grep -i '[X]vnc' | awk '{print $1}'); do
  kill -9 "$pid" 2>/dev/null || true
done
rm -f "/tmp/.X${DISP}-lock" "/tmp/.X11-unix/X${DISP}" \
      "$TMPDIR/.X${DISP}-lock" "$TMPDIR/.X11-unix/X${DISP}" 2>/dev/null || true
sleep 1

# --- audio ------------------------------------------------------------------
pulseaudio --start \
  --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
  --exit-idle-time=-1 2>/dev/null

# --- Xvnc :DISP (localhost only, no X11 TCP, VNC-password auth) --------------
# -nolisten tcp is mandatory: Android blocks the X11 TCP port and Xvnc
# otherwise dies with "Cannot establish any listening sockets".
# Socket lands in $TMPDIR/.X11-unix, shared into proot via --shared-tmp.
echo ">> starting Xvnc :$DISP ..."
setsid Xvnc ":$DISP" -localhost -nolisten tcp -rfbport "$RFBPORT" \
  -rfbauth "$HOME/.vnc/passwd" -geometry "$GEOM" -depth "$DEPTH" \
  -SecurityTypes VncAuth </dev/null >"$HOME/.vnc/Xvnc.log" 2>&1 &
sleep 3

# --- xrdp bridge (RDP 3389 -> VNC 5902); no sesman auth involved -------------
echo ">> starting xrdp ..."
# xrdp daemonizes itself and logs to $PREFIX/var/log/xrdp.log.
# Don't swallow startup errors: verify it stayed up, else dump its log.
xrdp
sleep 2
if ! pgrep -x xrdp >/dev/null; then
  echo "!! xrdp failed to start - tail of xrdp.log:" >&2
  tail -n 20 "$PREFIX/var/log/xrdp.log" >&2
  exit 1
fi

# --- launch i3 inside proot Arch as user jan, on display :DISP --------------
echo ">> starting i3 in proot on :$DISP ..."
proot-distro login "$DISTRO" \
  --user "$USER" \
  --shared-tmp \
  --bind "$HOME/.dotfiles:/home/$USER/.dotfiles" \
  --bind "$HOME/storage:/home/$USER/storage" \
  --bind "$HOME/.ssh:/home/$USER/.ssh" \
  -- bash -c "
  export DISPLAY=:$DISP
  export PULSE_SERVER=tcp:127.0.0.1:4713

  # No GPU: stub out picom (compositor not needed / would fail without GL).
  mkdir -p /usr/local/bin
  echo '#!/bin/sh' > /usr/local/bin/picom
  chmod +x /usr/local/bin/picom

  # Remap Alt to Mod4 (Super) after i3 starts.
  (sleep 3 && xmodmap -e 'remove mod1 = Alt_L' -e 'add mod4 = Alt_L') &

  # Separate config: shared bindings/theme, no desktop-only autostarts.
  dbus-launch --exit-with-session i3 -c ~/.dotfiles/i3/config-xrdp
"
