#!/bin/sh
# Thin client: boot -> autologin tty1 -> bare X -> fullscreen FreeRDP.
# Target: HP Compaq Mini 311 (Atom N270/N280, i686 only, dead battery)
# on a minimal Debian 12 i386 install (no desktop task selected).
# rotz has no i686 build, so this is a plain script instead of a dot.yaml.
#
# Usage (as root, from this directory):
#   ./setup.sh '<host:port> [xfreerdp args]'...
#   e.g. ./setup.sh '192.168.1.60:3392 /rfx' 'phone.lan:3389 /gfx /u:jan' 
# Each target becomes a menu entry. Re-run to change targets; idempotent.
set -eu
[ $# -gt 0 ] || { echo "usage: setup.sh <host:port>..." >&2; exit 1; }
user=rdp
here=$(cd "$(dirname "$0")" && pwd)

apt-get update
apt-get install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-nouveau \
  xinit x11-xserver-utils xterm fonts-dejavu-core freerdp2-x11

id "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"

printf '%s\n' "$@" > /etc/thinclient.targets
rm -f /etc/thinclient.conf      # pre-menu single-target config
install -m 0755 "$here/rdp-pick" /usr/local/bin/rdp-pick

install -o "$user" -m 0644 "$here/xinitrc" "/home/$user/.xinitrc"
install -o "$user" -m 0644 "$here/bash_profile" "/home/$user/.bash_profile"

# Autologin on tty1 only; other ttys keep a normal login for maintenance.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $user --noclear %I \$TERM
EOF

# Dead battery = always on mains: lid close and idle must never suspend.
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/thinclient.conf <<EOF
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
IdleAction=ignore
EOF
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

systemctl daemon-reload
echo "done: reboot to start the RDP menu ($*)"
