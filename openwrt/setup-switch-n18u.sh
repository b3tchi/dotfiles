#!/bin/sh
# OpenWrt config for the RT-N18U as a dumb wired switch behind the AX53U edge.
# All 5 ports (lan1-4 + wan) bridged into br-lan; static mgmt IP; no DHCP/DNS/
# firewall. No Wi-Fi: OpenWrt ships no driver for this radio (nothing to strip).
#
# Flashed from FreshTomato (see README "RT-N18U switch"), then on the bench:
#   ssh root@192.168.1.1 'cat > /etc/dropbear/authorized_keys' < ~/.ssh/id_ed25519.pub
#   ssh root@192.168.1.1 'sh -s' < setup-switch-n18u.sh
#   ssh root@192.168.1.1 reboot     # comes back at 192.168.1.3
# Then cable any port to the AX53U LAN. Root password: set via `passwd`
# (secrets stay out of the repo).
set -e

# --- system ---
uci set system.@system[0].hostname='sw-n18u'
uci set system.@system[0].zonename='Europe/Prague'
uci set system.@system[0].timezone='CET-1CEST,M3.5.0,M10.5.0/3'

# --- bridge every port (wan too) ---
uci delete network.@device[0].ports
for p in lan1 lan2 lan3 lan4 wan; do uci add_list network.@device[0].ports="$p"; done
uci -q delete network.wan || true
uci -q delete network.wan6 || true
uci -q delete network.@device[1] || true   # wan device section (macaddr)

# --- static mgmt IP on the main LAN (statics range .2-.50) ---
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.1.3'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.1.1'
uci -q delete network.lan.dns || true
uci add_list network.lan.dns='192.168.1.1'
uci -q delete network.lan.ip6assign || true

# --- no DHCP / DNS / RA / firewall: the AX53U owns all of that ---
uci set dhcp.lan.ignore='1'
uci commit
for s in dnsmasq odhcpd firewall; do /etc/init.d/$s disable 2>/dev/null || true; done
