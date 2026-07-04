#!/bin/bash
# Full-proot RDP desktop, UID-SAFE model: Xvnc + i3 + pulseaudio + xrdp ALL run
# as jan (uid 10533) in one proot login. xrdp is a plain bridge 3389 -> a
# jan-owned Xvnc:5902 using VNC-password auth. NO xrdp-sesman.
#
# Why not sesman/PAM: under proot fake-root, xrdp-sesman's setuid(jan) leaks the
# real uid (10532) instead of jan's mapped 10533, so the session can't write
# /home/jan or /run/user/10533 -> broken i3 (no IPC, dead keybinds). Running the
# whole stack as jan via a uid-MAPPED login avoids setuid entirely.
#
# RUN AS JAN (uid-mapped login, NOT su/root - su would re-introduce the leak):
#   (from Termux)  proot-distro login archlinux --user jan
#   (in proot)     bash ~/.dotfiles/scripts/termux/start-i3-xrdp-proot.sh
# Then: RDP client -> 127.0.0.1:3389 ; no username ; password = VNC password.
#
# One-time setup:
#   pacman -S tigervnc pulseaudio dbus i3-wm xorg-xmodmap   (xrdp via: yay -S xrdp)
#   vncpasswd                # creates ~/.vnc/passwd (the RDP login password)
#   xrdp.ini [Xvnc] must have: username=na password=ask ip=127.0.0.1 port=5902
set -u

DISP=2                 # X display :2
RFBPORT=5902           # must match xrdp.ini [Xvnc] port=
GEOM="1280x720"
DEPTH=24
I3_CONFIG="$HOME/.dotfiles/i3/config-xrdp"

# --- must be the uid-MAPPED jan, not root and not su'd (10532 leak) ---------
if [ "$(id -u)" = "0" ]; then
  echo "!! run as jan, not root:  proot-distro login archlinux --user jan" >&2
  exit 1
fi
if [ "$(id -un)" != "jan" ]; then
  echo "!! expected user 'jan' (uid $(id -u), name $(id -un))" >&2
  exit 1
fi

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export TMPDIR="${TMPDIR:-/tmp}"
mkdir -p "$XDG_RUNTIME_DIR" "$HOME/.vnc" /tmp/.X11-unix 2>/dev/null
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

for b in Xvnc i3 xrdp dbus-launch pulseaudio; do
  command -v "$b" >/dev/null 2>&1 || { echo "!! missing: $b" >&2; exit 1; }
done
if [ ! -f "$HOME/.vnc/passwd" ]; then
  echo "!! no ~/.vnc/passwd - create one:  vncpasswd" >&2
  exit 1
fi
if [ ! -f "$I3_CONFIG" ]; then
  echo "!! i3 config not found: $I3_CONFIG" >&2
  exit 1
fi

# --- kill previous (jan-owned only) -----------------------------------------
pkill -x xrdp 2>/dev/null || true
for pid in $(ps -e 2>/dev/null | grep -i '[X]vnc' | awk '{print $1}'); do
  kill -9 "$pid" 2>/dev/null || true   # ignores procs we don't own (old sesman :10)
done
rm -f "/tmp/.X${DISP}-lock" "/tmp/.X11-unix/X${DISP}" 2>/dev/null || true
rm -f /run/xrdp/*.pid /var/run/xrdp/*.pid 2>/dev/null || true
sleep 1

# --- audio ------------------------------------------------------------------
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1

# --- Xvnc :DISP as jan (VNC-password auth, localhost, no X11 TCP) ------------
echo ">> starting Xvnc :$DISP (rfb $RFBPORT) as jan ..."
setsid Xvnc ":$DISP" -localhost -nolisten tcp -rfbport "$RFBPORT" \
  -rfbauth "$HOME/.vnc/passwd" -geometry "$GEOM" -depth "$DEPTH" \
  -SecurityTypes VncAuth </dev/null >"$HOME/.vnc/Xvnc.log" 2>&1 &
sleep 3
if ! pgrep -x Xvnc >/dev/null; then
  echo "!! Xvnc failed - tail ~/.vnc/Xvnc.log:" >&2; tail -n 15 "$HOME/.vnc/Xvnc.log" >&2; exit 1
fi

# --- i3 on :DISP as jan (no sesman; i3 owns the session) --------------------
echo ">> starting i3 on :$DISP as jan ..."
export DISPLAY=":$DISP"
# No GPU: stub picom so the i3 autostart can't fail on missing GL.
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\n' > "$HOME/.local/bin/picom-stub"; chmod +x "$HOME/.local/bin/picom-stub"
# Alt -> Mod4 remap ($mod=Mod4). Re-run once the WM is up.
( sleep 3 && DISPLAY=":$DISP" xmodmap -e 'remove mod1 = Alt_L' -e 'add mod4 = Alt_L' >/dev/null 2>&1 ) &
setsid bash -c "export DISPLAY=:$DISP; export QT_QUICK_BACKEND=software; export QS_RDP=1; exec dbus-launch --exit-with-session i3 -c '$I3_CONFIG'" \
  </dev/null >"$HOME/.vnc/i3.log" 2>&1 &
sleep 2
if ! pgrep -x i3 >/dev/null; then
  echo "!! i3 failed - tail ~/.vnc/i3.log:" >&2; tail -n 15 "$HOME/.vnc/i3.log" >&2; exit 1
fi

# --- xrdp bridge (3389 -> Xvnc:5902) as jan; NO sesman ----------------------
echo ">> starting xrdp bridge as jan ..."
xrdp >"$HOME/.vnc/xrdp.log" 2>&1
sleep 2
if ! pgrep -x xrdp >/dev/null; then
  echo "!! xrdp failed - tail ~/.vnc/xrdp.log:" >&2; tail -n 20 "$HOME/.vnc/xrdp.log" >&2; exit 1
fi

echo ""
echo ">> up (all as jan / uid $(id -u)). RDP -> 127.0.0.1:3389"
echo "   no username; password = your VNC password (~/.vnc/passwd)"
echo "   logs: ~/.vnc/{Xvnc,i3,xrdp}.log   stop: pkill -x xrdp; pkill -x Xvnc; pkill -x i3"
