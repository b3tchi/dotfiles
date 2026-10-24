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
# Static reservation example (reserve the old .1.2 for revo, etc.):
#   uci add dhcp host; uci set dhcp.@host[-1].mac='D0:27:88:..'; \
#   uci set dhcp.@host[-1].ip='192.168.1.2'; uci set dhcp.@host[-1].name='revo'

# --- Wi-Fi: structure only; enable + set SSID/PSK in LuCI (PSK stays off-repo) ---
# radio0 = 2.4GHz (b3net), radio1 = 5GHz (b3net-5g). Set country, leave enabled.
uci set wireless.radio0.country='CZ'
uci set wireless.radio1.country='CZ'

# --- SSH: key is in /etc/dropbear/authorized_keys; keep LAN-only (default).
#     Leave PasswordAuth until the root password is set in LuCI, then lock:
#       uci set dropbear.@dropbear[0].PasswordAuth='off'
#       uci set dropbear.@dropbear[0].RootPasswordAuth='off'

uci commit
echo "base committed — reload network/dhcp or reboot; set root pass + Wi-Fi in LuCI"
