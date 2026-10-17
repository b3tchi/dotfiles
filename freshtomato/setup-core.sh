#!/bin/sh
# FreshTomato core config — LAN / DHCP / DNS / HTTPS / lockdown
#
# Idempotent. Push over SSH:   ssh root@<router> 'sh -s' < setup-core.sh
# Then apply without reboot:    ssh root@<router> 'service dnsmasq restart; service httpd restart'
#
# WireGuard is configured in the GUI (VPN Tunneling -> WireGuard): the per-peer
# wg0_peers nvram string is build-specific and brittle to hand-edit, and the GUI
# generates keypairs + a phone QR. See README.md.
#
# Edit these per box before pushing:
LAN_IP=192.168.2.1
LAN_MASK=255.255.255.0
DHCP_START=192.168.2.100   # dynamic pool; statics live below it (.2-.50)
DHCP_END=192.168.2.200
DHCP_LEASE=1440            # minutes

set -e

# --- LAN ---
nvram set lan_ipaddr="$LAN_IP"
nvram set lan_netmask="$LAN_MASK"

# --- DHCP ---
nvram set dhcpd_startip="$DHCP_START"
nvram set dhcpd_endip="$DHCP_END"
nvram set dhcp_lease="$DHCP_LEASE"
# Static reservations: dhcpd_static = MAC<IP<hostname<lease  (entries joined by >)
# keep them OUTSIDE the dynamic pool (use .2-.50). Example:
#   nvram set dhcpd_static="AA:BB:CC:DD:EE:FF<192.168.2.2<ap-n18u<"

# --- DNS: DoT (stubby) upstream + DNSSEC + intercept + anti-rebind ---
nvram set stubby_proxy=1          # DNS-over-TLS (resolvers preset to Cloudflare)
nvram set dnssec_enable=1
nvram set dns_intcpt=1            # force LAN clients onto this resolver
nvram set dns_norebind=1

# --- Admin UI: HTTPS only, persist self-signed cert across reboots ---
nvram set http_enable=0
nvram set https_enable=1
nvram set https_crt_save=1

# --- Lockdown ---
nvram set telnetd_eas=0           # telnet off
nvram set sshd_pass=0             # SSH key-only (no password login)
nvram set remote_management=0     # no WAN admin (http)
nvram set remote_mgt_https=0      # no WAN admin (https)
nvram set upnp_enable=0           # UPnP off

nvram commit
echo "core config committed — restart services or reboot to apply"
