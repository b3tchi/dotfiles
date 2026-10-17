#!/bin/sh
# FreshTomato AP mode — convert a box to a bridged access point behind the
# main router (same LAN, no routing, no DHCP).
#
# APPLY AT INSTALL TIME ONLY, with the box cabled main-LAN -> this box's LAN
# port. It moves the LAN IP onto the main subnet and turns the DHCP server off,
# so a management link that relied on this box's own DHCP will drop.
#
#   ssh root@<current-ip> 'sh -s' < ap-mode.sh
#   ssh root@192.168.1.2 'service net restart'   # or reboot
#
# Wi-Fi (SSID / WPA2 / channel) is set in the GUI, not here — the PSK should not
# pass through a shell. Current default leaves Wi-Fi OPEN; set WPA2-AES first.
#
# Edit per box:
AP_IP=192.168.1.2            # free address on the MAIN router's subnet
MAIN_ROUTER=192.168.1.1      # gateway + DNS = the edge router

set -e

# LAN onto main subnet, point at the edge router
nvram set lan_ipaddr="$AP_IP"
nvram set lan_netmask=255.255.255.0
nvram set lan_gateway="$MAIN_ROUTER"
nvram set lan_dns="$MAIN_ROUTER"

# DHCP server OFF (lan_proto=static is the toggle) — main router serves leases
nvram set lan_proto=static

# WAN unused in AP mode
nvram set wan_proto=disabled

nvram commit
echo "AP network config committed — box will be at $AP_IP; set Wi-Fi WPA2 in GUI"
