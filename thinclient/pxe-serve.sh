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
  ufw delete allow in on "$iface" || true
  ufw route delete allow in on "$iface" || true
  iptables -D FORWARD -i "$iface" -j ACCEPT || true
  iptables -D FORWARD -o "$iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true
else
  if [ ! -e "$root/pxelinux.0" ]; then
    mkdir -p "$root"
    curl -fL "$url" | tar -xz -C "$root"
  fi
  # Boot straight into the unattended install; preseed.cfg comes over HTTP:
  #   python3 -m http.server -b <cable-ip> -d thinclient 8000
  # Set the BIOS to boot the disk first and pick network one-time (boot
  # menu), or every reboot reinstalls.
  ip=$(nmcli -g IP4.ADDRESS con show "$con" | cut -d/ -f1)
  cat > "$root/pxelinux.cfg/default" <<EOF
default auto
prompt 0
timeout 0
label auto
  kernel debian-installer/i386/linux
  append initrd=debian-installer/i386/initrd.gz auto=true priority=critical url=http://$ip:8000/preseed.cfg hostname=mini311 domain= locale=en_US.UTF-8 keymap=us vga=788 --- quiet
EOF
  mkdir -p "$(dirname "$conf")"
  printf 'enable-tftp\ntftp-root=%s\ndhcp-boot=pxelinux.0\n' "$root" > "$conf"
  # ufw (default INPUT+FORWARD DROP) blocks NM shared mode's DNS/TFTP and
  # NAT; the cable leads only to the mini, so trust it wholesale.
  ufw allow in on "$iface"
  ufw route allow in on "$iface"
  # Docker sets the iptables FORWARD policy to DROP, which kills NM's NAT.
  iptables -C FORWARD -i "$iface" -j ACCEPT 2>/dev/null ||
    iptables -I FORWARD 1 -i "$iface" -j ACCEPT
  iptables -C FORWARD -o "$iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
    iptables -I FORWARD 1 -o "$iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi

nmcli con down "$con" >/dev/null 2>&1 || true
nmcli con up "$con"
