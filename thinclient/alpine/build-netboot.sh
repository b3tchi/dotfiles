#!/bin/sh
# Stage a diskless Alpine x86 netboot for the Mini 311 (runs from RAM, the
# disk is never touched). The overlay brings only networking + sshd + the
# fleet SSH key; thinclient/alpine/setup.sh does the rest over SSH.
#
# Usage (no root):  ./build-netboot.sh <http-ip>     e.g. 192.168.1.60
# Then serve the stage dir over HTTP on :8000 and boot it with PXE — the
# script prints the exact commands.
set -eu
ip=${1:?usage: build-netboot.sh <http-ip>}
ver=3.24.3; branch=v3.24
mirror=http://dl-cdn.alpinelinux.org/alpine
stage=${XDG_CACHE_HOME:-$HOME/.cache}/thinclient-alpine
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINcXUjXpfDE34noiIXN12NSSUYcwZqsZgqzFrxB5QFFd jan@pc'

mkdir -p "$stage"
[ -e "$stage/boot/vmlinuz-lts" ] ||
  curl -fsSL "$mirror/$branch/releases/x86/alpine-netboot-$ver-x86.tar.gz" | tar -xz -C "$stage"

# --- apkovl: unpacked over / at boot ---------------------------------------
ovl=$(mktemp -d)
trap 'rm -rf "$ovl"' EXIT
chmod 755 "$ovl"                 # tar root = /: mktemp's 700 would lock out non-root
mkdir -p "$ovl/etc/apk" "$ovl/etc/network" "$ovl/root/.ssh"
echo mini311 > "$ovl/etc/hostname"
printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' \
  > "$ovl/etc/network/interfaces"
printf '%s/%s/main\n%s/%s/community\n' "$mirror" "$branch" "$mirror" "$branch" \
  > "$ovl/etc/apk/repositories"
printf 'alpine-base\nopenssh\n' > "$ovl/etc/apk/world"
echo "$key" > "$ovl/root/.ssh/authorized_keys"
chmod 700 "$ovl/root" "$ovl/root/.ssh"; chmod 600 "$ovl/root/.ssh/authorized_keys"

# With an apkovl present, init creates no default runlevels: list them all.
rl() { mkdir -p "$ovl/etc/runlevels/$1"; shift_=$1; shift
       for s; do ln -sf "/etc/init.d/$s" "$ovl/etc/runlevels/$shift_/$s"; done; }
rl sysinit devfs dmesg mdev hwdrivers
rl boot modules hostname sysctl bootmisc syslog hwclock
rl default networking sshd
rl shutdown mount-ro killprocs savecache

tar -C "$ovl" --owner=0 --group=0 -czf "$stage/mini311.apkovl.tar.gz" .

# --- pxelinux menu (TFTP) ---------------------------------------------------
mkdir -p "$stage/pxelinux.cfg"
cat > "$stage/pxelinux.cfg/default" <<EOF
default alpine
prompt 0
timeout 0
label alpine
  kernel boot/vmlinuz-lts
  append initrd=boot/initramfs-lts ip=dhcp alpine_repo=$mirror/$branch/main modloop=http://$ip:8000/boot/modloop-lts apkovl=http://$ip:8000/mini311.apkovl.tar.gz modules=loop,squashfs,af_packet,forcedeth quiet
EOF

cat <<EOF
staged in $stage
serve HTTP:  python3 -m http.server -b $ip -d $stage 8000
serve PXE (root; Debian's pxelinux.0 + ldlinux.c32 from /srv/tftp/mini311):
  sudo sh -c 'mkdir -p /srv/tftp/alpine && cp -r $stage/boot $stage/pxelinux.cfg /srv/tftp/alpine/ && cp /srv/tftp/mini311/pxelinux.0 /srv/tftp/mini311/ldlinux.c32 /srv/tftp/alpine/ && chmod -R a+rX /srv/tftp/alpine'
  sudo dnsmasq --no-daemon --port=0 --log-dhcp --interface=wlp1s0 --bind-interfaces \\
    --dhcp-range=${ip%.*}.0,proxy,255.255.255.0 --pxe-service=x86PC,"Alpine RAM",pxelinux \\
    --enable-tftp --tftp-root=/srv/tftp/alpine
EOF
