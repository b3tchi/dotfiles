#!/bin/sh
# OpenWrt base config for the RT-AX53U edge — LAN / DHCP / SSH / system.
# Runs with only base packages (no WAN needed). Apply on the bench:
#   ssh root@192.168.1.1 'sh -s' < setup-base.sh
#
# Wi-Fi PSK and the root password are set in LuCI (not here — secrets stay out
# of the shell/repo). WireGuard + DNS-over-TLS need internet; see setup-edge.sh,
# run after cutover.
set -e

# --- system ---
uci set system.@system[0].hostname='ax53u'
uci set system.@system[0].zonename='Europe/Prague'
uci set system.@system[0].timezone='CET-1CEST,M3.5.0,M10.5.0/3'

# --- LAN (keep 192.168.1.1 = final subnet) ---
uci set network.lan.ipaddr='192.168.1.1'
uci set network.lan.netmask='255.255.255.0'

# --- DHCP: dynamic .100-.200, statics .2-.50, 1 day lease ---
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='101'
uci set dhcp.lan.leasetime='1d'
# Static DHCP reservation example (restore an old fixed IP, outside the pool):
#   uci add dhcp host; uci set dhcp.@host[-1].mac='FC:3F:DB:0D:4E:C3'; \
#   uci set dhcp.@host[-1].ip='192.168.1.99'; uci set dhcp.@host[-1].name='elitedesk'
# swift (Acer Swift laptop, wlp1s0) -> fixed .60 + name 'swift' (resolves swift.lan).
# NB: if NetworkManager randomizes MAC per-SSID this won't match — pin the real MAC.
uci -q delete dhcp.swift || true
uci set dhcp.swift=host
uci set dhcp.swift.mac='74:4c:a1:50:86:4f'
uci set dhcp.swift.ip='192.168.1.60'
uci set dhcp.swift.name='swift'

# nix-fleet hosts: these MUST keep fixed IPs — the NAS NFS exports are
# IP-restricted (/volume1/nixos-<host> allows only each host's fixed IP + .60
# the publisher). Without these reservations the boxes grab pool IPs, fall off
# the NAS allow-list, and the NFS config-pull fails ('access denied').
uci -q delete dhcp.revo || true
uci set dhcp.revo=host
uci set dhcp.revo.mac='d0:27:88:c3:fe:02'
uci set dhcp.revo.ip='192.168.1.2'
uci set dhcp.revo.name='revo'
uci -q delete dhcp.elitedesk || true
uci set dhcp.elitedesk=host
uci set dhcp.elitedesk.mac='fc:3f:db:0d:4e:c3'
uci set dhcp.elitedesk.ip='192.168.1.99'
uci set dhcp.elitedesk.name='elitedesk'
# pi -> 192.168.1.6 (NAS export allows .6). MAC unknown — fill when pi is up:
#   uci set dhcp.pi=host; uci set dhcp.pi.mac='<pi-mac>'; \
#   uci set dhcp.pi.ip='192.168.1.6'; uci set dhcp.pi.name='pi'

# --- Static DNS record for the NAS (static IP .245, no DHCP lease to auto-name) ---
# makes 'nas' / 'nas.lan' resolve. Add similar for any other static-IP host.
uci -q delete dhcp.nas || true
uci set dhcp.nas=domain
uci set dhcp.nas.name='nas'
uci set dhcp.nas.ip='192.168.1.245'

# --- Wi-Fi: SSID/band/encryption structure; PSK stays off-repo (set in LuCI) ---
# radio0 = 2.4GHz (b3net), radio1 = 5GHz (b3net-5g).
uci set wireless.radio0.country='CZ'
uci set wireless.radio0.channel='1'
uci set wireless.radio1.country='CZ'
uci set wireless.radio1.channel='36'
uci set wireless.radio1.htmode='HE80'
# iface0 -> b3net (2.4), iface1 -> b3net-5g (5). encryption psk2 (WPA2-AES).
uci set wireless.default_radio0.ssid='b3net'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.network='lan'
uci set wireless.default_radio0.disabled='0'
uci set wireless.default_radio1.ssid='b3net-5g'
uci set wireless.default_radio1.encryption='psk2'
uci set wireless.default_radio1.network='lan'
uci set wireless.default_radio1.disabled='0'
# PSK NOT set here — set both radios' key in LuCI (or: uci set
# wireless.default_radioN.key='...'; same password on both for one roaming net).

# --- SSH: key is in /etc/dropbear/authorized_keys; keep LAN-only (default).
#     Leave PasswordAuth until the root password is set in LuCI, then lock:
#       uci set dropbear.@dropbear[0].PasswordAuth='off'
#       uci set dropbear.@dropbear[0].RootPasswordAuth='off'

uci commit
echo "base committed — reload network/dhcp or reboot; set root pass + Wi-Fi in LuCI"
