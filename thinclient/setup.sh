#!/bin/sh
# Thin client: boot -> autologin tty1 -> bare X -> fullscreen FreeRDP.
# Target: HP Compaq Mini 311 (Atom N270/N280, i686 only, dead battery)
# on a minimal Debian 12 i386 install (no desktop task selected).
# rotz has no i686 build, so this is a plain script instead of a dot.yaml.
#
# Usage (as root, from this directory):
#   ./setup.sh <rdp-host> [port]      e.g. ./setup.sh 192.168.1.20 3391
# Re-run to change the target; idempotent.
set -eu
host=${1:?usage: setup.sh <rdp-host> [port]}
port=${2:-3391}                  # 3391 = WSL i3 xrdp (see xrdp/dot.yaml)
user=rdp
here=$(cd "$(dirname "$0")" && pwd)

apt-get update
apt-get install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-nouveau \
  xinit x11-xserver-utils freerdp2-x11

id "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"

printf 'RDP_HOST=%s\nRDP_PORT=%s\n' "$host" "$port" > /etc/thinclient.conf

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
echo "done: reboot to start the RDP session ($host:$port)"
