# FreshTomato routers

Config for the two ASUS routers running FreshTomato 2026.4 (K26ARM).

| Role (target) | Router | Build | LAN |
|---|---|---|---|
| Edge — DHCP + DNS + WireGuard-in | RT-AC66U B1 | `VPN-64K` (dual-core) | `192.168.2.1` |
| AP (2.4 GHz) | RT-N18U | `VPN-64K-NOSMP` (single-core) | `192.168.2.1`* |

\* During staged cutover the N18U runs as a temporary edge at `192.168.2.1`;
once the B1 takes over it is demoted to a bridged AP (DHCP off).

Stock ASUS firmware is EOL on both; Asuswrt-Merlin dropped the AC66U B1
(whole AC68U family). FreshTomato is the maintained option. OpenWrt is out —
the Broadcom `wl` Wi-Fi blob won't run on modern OpenWrt kernels, so its 5 GHz
is weak on these boards.

## Firmware

FreshTomato ARM downloads are a plain file index (the website's router DB is
stale):

    https://freshtomato.org/downloads/freshtomato-arm/<year>/<ver>/

Exact 2026.4 images:
- `freshtomato-RT-N18U-K26ARM-2026.4-VPN-64K-NOSMP.zip`  (NOSMP = single-core, required)
- `freshtomato-RT-AC66U_B1-K26ARM-2026.4-VPN-64K.zip`    (ARM build, NOT the MIPS AC66U)

The `.zip` holds a `.trx` (valid image starts with `HDR0` = `48445230`) plus
CHANGELOG + README. VPN build chosen over AIO: smaller attack surface, lighter
on RAM, still ships WireGuard + OpenVPN.

## Flash (web UI)

1. Admin UI -> Firmware Upgrade -> **Reset to Default settings**.
2. Pick the `.trx`. Wait for the full progress bar + success (~3-5 min). **No power cut.**
3. Reboots to default `192.168.1.1`. First FreshTomato boot rebuilds nvram (~1-2 min).
4. Default web login: **`root` / `admin`** (not `admin`/`admin`).
5. If the UI looks half-broken after a cross-firmware flash: Administration ->
   Configuration -> erase NVRAM (thorough).

### Reaching it when its LAN clashes with your main network

A fresh box sits at `192.168.1.1`, same subnet as the main router. From a Linux
box with a spare wired port (DHCP client on it), pin just that IP to the port so
the browser hits the new router, not the main one:

    sudo ip route add 192.168.1.1/32 dev <iface>
    # ... set LAN IP to 192.168.2.1 in the UI, it reboots ...
    sudo ip route del 192.168.1.1/32 dev <iface>
    sudo nmcli con down <profile>; sleep 4; sudo nmcli con up <profile>

Internet (default route via Wi-Fi) stays up throughout.

## Core config

`setup-core.sh` — LAN, DHCP (dynamic `.100-.200`, statics `.2-.50`), DNS
(DoT + DNSSEC + intercept + anti-rebind), HTTPS-only UI (persistent cert), and
lockdown (telnet/UPnP/WAN-admin off, SSH key-only). Edit the vars at the top per
box, then:

    ssh root@192.168.2.1 'sh -s' < setup-core.sh
    ssh root@192.168.2.1 'service dnsmasq restart; service httpd restart'

Most lockdown values are already FreshTomato defaults; the script is explicit so
it's reproducible and auditable.

## SSH bootstrap

Enable in Administration -> Admin Access: SSH Daemon on, WAN access off, paste
the pubkey into Authorized Keys, keep password login on until key login is
proven, then `setup-core.sh` sets `sshd_pass=0`.

Note: dropbear on the single-core N18U gets wedged by rapid back-to-back SSH
connections (port 22 goes dead while ping/HTTPS stay up). Recover by toggling
SSH Daemon off/Save/on/Save in the UI. The dual-core B1 does not show this.

## WireGuard-in (remote admin)

Terminates on the **B1** (edge). Reach the LAN UI over the tunnel; never expose
the admin page to WAN. Done in the GUI (VPN Tunneling -> WireGuard), not
scripted — the `wg0_peers` nvram string is build-specific (peers joined by `>`,
fields by `<`) and the GUI generates keypairs + a phone QR.

Server (`wg0`): Server mode, tunnel `10.22.0.1/24`, listen `51820`, NAT on,
"redirect internet traffic" OFF (split tunnel). Generate the server keypair.

Each peer: generate keypair, server-side Allowed IPs = that peer's `/32`
(`10.22.0.2/32`, `.3/32`, ...). In the client config:

    AllowedIPs = 192.168.2.0/24, 10.22.0.0/24   # reach LAN + tunnel only
    DNS        = 192.168.2.1                      # lookups ride the tunnel

Endpoint = the WAN public IP; it's dynamic, so set DDNS (Basic -> DDNS) and use
the hostname as the endpoint. Forward/open UDP `51820` on the edge.

## Cutover order (staged)

1. N18U -> FreshTomato, run as temporary edge; prove DHCP/DNS as edge.
2. B1 -> FreshTomato, bring up as edge with the same `setup-core.sh`.
3. Swap: B1 takes the WAN; demote N18U to a bridged AP (DHCP off).

Only one edge/DHCP server on the live LAN at a time — each swap is a clean
replace. Reuse one WireGuard *server* key across the swap so peer configs don't
change.
