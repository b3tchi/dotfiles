#!/bin/sh
# OpenWrt edge features for the RT-AX53U — WireGuard-in + DNS-over-TLS.
# Needs INTERNET (apk fetches packages), so run AFTER cutover (WAN live):
#   ssh root@192.168.1.1 'sh -s' < setup-edge.sh
#
# WireGuard private keys are generated on the box and never leave it; peer
# PUBLIC keys are pasted below. Nothing secret is committed to the repo.
set -e

# --- packages ---
apk update
apk add wireguard-tools kmod-wireguard luci-proto-wireguard qrencode \
        https-dns-proxy luci-app-https-dns-proxy

# --- DNS-over-HTTPS (https-dns-proxy -> Cloudflare + Quad9); dnsmasq uses it ---
# LuCI app wires dnsmasq to 127.0.0.1:5053 automatically. Verify after:
#   uci show https-dns-proxy ; logread | grep https-dns
/etc/init.d/https-dns-proxy enable
/etc/init.d/https-dns-proxy start

# --- WireGuard-in server (wg0) ---
# Generate server keys on the box (once):
if [ ! -f /etc/wireguard/wg0.key ]; then
  mkdir -p /etc/wireguard
  wg genkey | tee /etc/wireguard/wg0.key | wg pubkey > /etc/wireguard/wg0.pub
  chmod 600 /etc/wireguard/wg0.key
fi
WG_KEY=$(cat /etc/wireguard/wg0.key)
echo "SERVER PUBKEY (put in peer configs): $(cat /etc/wireguard/wg0.pub)"

uci -q delete network.wg0 || true   # tolerate absence (set -e)
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="$WG_KEY"
uci set network.wg0.listen_port='51820'
uci add_list network.wg0.addresses='10.22.0.1/24'

# Peer(s): paste each device's PUBLIC key + its tunnel /32. Repeat the block.
#   uci -q delete network.wgpeer_phone
#   uci set network.wgpeer_phone=wireguard_wg0
#   uci set network.wgpeer_phone.public_key='<PHONE_PUBKEY>'
#   uci add_list network.wgpeer_phone.allowed_ips='10.22.0.2/32'
#   uci set network.wgpeer_phone.description='phone'

# --- firewall: wg0 into the lan zone (reach LAN over tunnel), open the port ---
uci -q delete firewall.wg || true   # tolerate absence (set -e)
uci set firewall.wg=rule
uci set firewall.wg.name='Allow-WireGuard'
uci set firewall.wg.src='wan'
uci set firewall.wg.dest_port='51820'
uci set firewall.wg.proto='udp'
uci set firewall.wg.target='ACCEPT'
# add wg0 to the lan zone's network list:
uci add_list firewall.@zone[0].network='wg0' 2>/dev/null || true

uci commit
# network RESTART (not reload): a freshly apk-installed proto handler
# (wireguard.sh) is only picked up by a full netifd restart; a reload leaves
# wg0 as proto 'none' / NO_DEVICE. Restart briefly bounces WAN (~5s).
/etc/init.d/network restart
/etc/init.d/firewall reload
echo "edge committed — add peers (see commented block), set DDNS, test from mobile"
