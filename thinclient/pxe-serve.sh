#!/bin/sh
# One-off PXE server for installing Debian 12 i386 on the Mini 311.
# proxyDHCP: the router keeps assigning IPs, dnsmasq only adds the boot
# file + TFTP — no OpenWrt change. Legacy BIOS PXE (the Mini 311 has no UEFI).
#
# Usage: sudo ./pxe-serve.sh        (Ctrl-C once the installer has booted)
# Netbook must be on wired ethernet. Firewall here must allow UDP 67/69/4011.
set -eu
root=${XDG_CACHE_HOME:-$HOME/.cache}/thinclient-pxe
url=http://deb.debian.org/debian/dists/bookworm/main/installer-i386/current/images/netboot/netboot.tar.gz

if [ ! -e "$root/pxelinux.0" ]; then
  mkdir -p "$root"
  curl -fL "$url" | tar -xz -C "$root"
fi

# --port=0: no DNS. Subnet = our LAN (openwrt/setup-base.sh).
exec dnsmasq --no-daemon --port=0 --log-dhcp \
  --dhcp-range=192.168.1.0,proxy,255.255.255.0 \
  --pxe-service=x86PC,"Debian 12 i386 installer",pxelinux \
  --enable-tftp --tftp-root="$root"
