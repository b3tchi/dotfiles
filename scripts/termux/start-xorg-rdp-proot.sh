#!/bin/bash
# Native-RDP stack in proot Arch: xrdp + xrdp-sesman + Xorg(xorgxrdp) + i3.
# No internal VNC hop. RUN AS ROOT inside proot:
#   (from Termux)  proot-distro login archlinux        # NOT --user jan
#   (in proot)     bash ~/.dotfiles/scripts/termux/start-xorg-rdp-proot.sh
# Then: RDP -> 127.0.0.1:3389, login jan / unix password.
#
# Notes / why this shape:
# - sesman must run as (fake-)root so pam_unix reads shadow directly; started
#   non-root it fails "pam_authenticate: System error".
# - /etc/pam.d/xrdp-sesman is a minimal pam_unix stack (Arch's default pulls in
#   pam_systemd_home/faillock which throw PAM_SYSTEM_ERR under proot).
# - xrdp.ini [Xorg] backend is enabled; xorg.conf uses the GPU-less xrdpdev
#   driver, so no /dev/dri needed.
# - startwm.sh / reconnectwm.sh remap Alt->Mod4 (and release the client's stuck
#   Super_L) so Alt is the i3 $mod.
# - A minimal system dbus is started so Xorg stops spamming
#   "dbus-core: error connecting to system bus" every 10s.
set -u

if [ "$(id -u)" != "0" ]; then
  echo "!! run as root (proot-distro login archlinux, no --user):  id -u must be 0" >&2
  exit 1
fi

# --- minimal system dbus (silences Xorg's system-bus retry spam) ------------
if [ ! -S /run/dbus/system_bus_socket ]; then
  echo ">> starting system dbus ..."
  mkdir -p /run/dbus
  dbus-uuidgen --ensure >/dev/null 2>&1 || true
  dbus-daemon --system --fork 2>/dev/null || echo "   (dbus-daemon failed; spam will persist but harmless)"
fi

# --- clear stale sesman pid/socket/lock -------------------------------------
pkill -x xrdp 2>/dev/null || true
pkill -x xrdp-sesman 2>/dev/null || true
sleep 1
rm -f /run/xrdp-sesman.pid /var/run/xrdp-sesman.pid \
      /run/xrdp/sesman.socket /var/run/xrdp/sesman.socket \
      /run/xrdp/.sesman.socket.lock 2>/dev/null || true

# --- sesman FIRST, then xrdp ------------------------------------------------
echo ">> starting xrdp-sesman ..."
xrdp-sesman
sleep 1
if ! pgrep -x xrdp-sesman >/dev/null; then
  echo "!! sesman failed - tail:" >&2; tail -n 15 /var/log/xrdp-sesman.log >&2; exit 1
fi
grep -q "Sesman now listening" <(tail -n 3 /var/log/xrdp-sesman.log) && echo "   sesman listening"

echo ">> starting xrdp ..."
xrdp
sleep 2
if ! pgrep -x xrdp >/dev/null; then
  echo "!! xrdp failed - tail:" >&2; tail -n 15 /var/log/xrdp.log >&2; exit 1
fi

echo ""
echo ">> native RDP up. connect: 127.0.0.1:3389  login: jan / <unix password>"
echo "   session log: /var/log/xrdp-sesman.log   Xorg: ~/.xorgxrdp.10.log"
echo "   stop: pkill -x xrdp; pkill -x xrdp-sesman"
