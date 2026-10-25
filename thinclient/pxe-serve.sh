#!/bin/sh
# PXE-install Debian 12 i386 on the Mini 311 over a direct cable.
# Assumes a NetworkManager "shared" connection on the cable (NM runs dnsmasq
# for DHCP + NATs our Wi-Fi), so the netinst also gets internet. We only drop
# a TFTP/boot-file snippet into NM's dnsmasq. Legacy BIOS PXE (no UEFI).
#
# Usage: sudo ./pxe-serve.sh [nm-connection]   default: pi-share
#        sudo ./pxe-serve.sh --off [nm-connection]
set -eu
off=; [ "${1:-}" = --off ] && { off=1; shift; }
con=${1:-pi-share}
root=/srv/tftp/mini311           # outside $HOME: dnsmasq drops to 'nobody'
conf=/etc/NetworkManager/dnsmasq-shared.d/pxe-mini311.conf
url=http://deb.debian.org/debian/dists/bookworm/main/installer-i386/current/images/netboot/netboot.tar.gz
iface=$(nmcli -g GENERAL.DEVICES con show "$con")

if [ -n "$off" ]; then
  rm -f "$conf"
  ufw delete allow in on "$iface" to any port 69 proto udp || true
else
  if [ ! -e "$root/pxelinux.0" ]; then
    mkdir -p "$root"
    curl -fL "$url" | tar -xz -C "$root"
  fi
  mkdir -p "$(dirname "$conf")"
  printf 'enable-tftp\ntftp-root=%s\ndhcp-boot=pxelinux.0\n' "$root" > "$conf"
  # NM's shared mode opens DHCP/DNS, not TFTP.
  ufw allow in on "$iface" to any port 69 proto udp
fi

nmcli con down "$con" >/dev/null 2>&1 || true
nmcli con up "$con"
