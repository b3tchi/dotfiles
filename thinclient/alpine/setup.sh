#!/bin/sh
# Alpine twin of ../setup.sh: boot -> autologin tty1 -> bare X -> FreeRDP 3.
# Same target menu files (rdp-pick, xinitrc, bash_profile) as the Debian one.
# Works on the diskless netboot (RAM test) and on a sys install; re-run after
# setup-disk to apply the disk-only bits (quiet extlinux boot).
#
# Usage (as root, from this directory):
#   ./setup.sh '<host:port> [xfreerdp args]'...
#   e.g. ./setup.sh '192.168.1.60:3392 /rfx' 'phone.lan:3389 /gfx /u:jan'
set -eu
[ $# -gt 0 ] || { echo "usage: setup.sh <host:port>..." >&2; exit 1; }
user=rdp
here=$(cd "$(dirname "$0")" && pwd)
top=$here/..

# Xorg's modesetting driver (built in) + gallium = nouveau with glamor.
apk add xorg-server xf86-input-libinput mesa-dri-gallium eudev \
  xinit xset xterm font-dejavu bash freerdp

# libinput needs udev for hotplugged input devices; mdev can't feed it.
setup-devd udev

# Rootless Xorg: owning tty1 (via login) + video/input groups is enough.
id "$user" >/dev/null 2>&1 || adduser -D -s /bin/bash "$user"
addgroup "$user" video; addgroup "$user" input

printf '%s\n' "$@" > /etc/thinclient.targets
install -m 0755 "$top/rdp-pick" /usr/local/bin/rdp-pick
install -o "$user" -m 0644 "$top/xinitrc" "/home/$user/.xinitrc"
install -o "$user" -m 0644 "$top/bash_profile" "/home/$user/.bash_profile"

# Autologin on tty1 only; other ttys keep a normal getty for maintenance.
sed -i "s|^tty1::respawn:.*|tty1::respawn:/bin/login -f $user|" /etc/inittab

# No acpid in any runlevel = lid close and idle never suspend (dead battery).
rc-update del acpid default 2>/dev/null || true

# Disk install only: no extlinux menu wait, quiet kernel.
if [ -f /etc/update-extlinux.conf ]; then
  sed -i -e 's/^timeout=.*/timeout=1/' -e 's/^hidden=.*/hidden=1/' \
    -e 's/^default_kernel_opts=.*/default_kernel_opts="quiet loglevel=3 vt.global_cursor_default=0"/' \
    /etc/update-extlinux.conf
  update-extlinux
fi

echo "done: reboot (or 'kill -HUP 1' + log out tty1) to start the RDP menu ($*)"
