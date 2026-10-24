# Router migration plan

Replace the old ASUS edge router with an **ASUS RT-AX53U running OpenWrt** as the
sole edge + Wi-Fi (dual-band, Wi-Fi 6). Keep the existing `192.168.1.0/24` subnet
so nothing with a hardcoded IP breaks. The Broadcom boxes (RT-AC66U B1, RT-N18U)
and the old router become shelved spares / rollback.

> Earlier revisions staged a FreshTomato edge (N18U interim -> B1). The AX53U
> purchase supersedes that: it's a better radio (Wi-Fi 6) and MediaTek, so it
> runs OpenWrt and goes straight in as the edge. FreshTomato notes below are kept
> for the spare Broadcom boxes; the AX53U config lives in `../openwrt/`.

## Why OpenWrt here (not FreshTomato)

The AX53U is **MediaTek MT7621A** (ramips/mt7621), not Broadcom. FreshTomato /
DD-WRT / Merlin are Broadcom-oriented and don't support it; OpenWrt's MediaTek
drivers are first-class (the opposite of the Broadcom situation, where OpenWrt's
Wi-Fi is weak). WireGuard is in-kernel on OpenWrt and fine on MT7621.

Trade-off: two firmware worlds. OpenWrt uses UCI (`/etc/config/*`, `uci` CLI),
not nvram — the FreshTomato `setup-core.sh` does NOT apply to the AX53U.

## Current state (2026-10)

| Device | Role | Addr | Notes |
|---|---|---|---|
| old ASUS | edge | `192.168.1.1` | `b3net` 2.4 + `b3net-5g` 5 GHz, DHCP for LAN |
| revo | NixOS host | `192.168.1.2` | nix-fleet box |
| RT-AX53U | new, boxed | — | MediaTek MT7621, to become the OpenWrt edge |
| RT-N18U | bench | `192.168.2.1` | FreshTomato 2026.4, configured — now a SPARE |
| RT-AC66U B1 | stock, untouched | — | now a SPARE |
| laptop | — | `192.168.1.60` (wifi) | USB-ethernet bench link |

Public IP `78.44.49.38` — routable (not CGNAT), so WireGuard-in is viable.

## Target state

| Device | Role | LAN IP | Wi-Fi | DHCP |
|---|---|---|---|---|
| **AX53U** | edge (OpenWrt) | `192.168.1.1` | `b3net` 2.4 + `b3net-5g` 5 GHz | server: dynamic `.100-.200`, statics `.2-.50` |
| old ASUS / B1 / N18U | shelved spares | — | — | — |

Edge does WAN + DHCP + DNS (DoT) + WireGuard-in + both Wi-Fi bands. `.1.2` stays
revo.

## Phase 0 — capture the old router's settings

WAN type (DHCP / PPPoE creds / static), WAN MAC (for clone), Wi-Fi SSIDs
(`b3net`, `b3net-5g`) + password + security, port forwards, DDNS hostname.

## Phase 1 — bench-flash + configure the AX53U (no downtime; old router live)

See `../openwrt/README.md` for the exact flash method (no web-UI flash on this
model — recovery-mode initramfs -> sysupgrade, or `mtd-write` over SSH; pick the
OpenWrt version carefully, bootloop reports exist).

1. Connect AX53U LAN -> laptop USB-ethernet; flash OpenWrt per `../openwrt/`.
2. Temp LAN `192.168.2.1` on the bench (avoid clashing with the live `.1.x`).
3. Apply `../openwrt/setup.sh` (UCI): LAN, DHCP (`.100-.200`), DNS (DoT via
   https-dns-proxy or stubby), firewall, SSH key, both Wi-Fi bands (WPA2/WPA3),
   WireGuard-in (`wg0`, split tunnel, peers, DNS push `192.168.1.1`).
4. WAN: set the type from Phase 0 (don't connect the WAN cable yet).

## Phase 2 — cutover (single, ~2 min drop)

1. (optional) Shut down revo cleanly.
2. Set the AX53U LAN to `192.168.1.1`, reboot.
3. **Power off the old ASUS.**
4. ISP/WAN cable -> AX53U WAN (MAC-clone if Phase 0 said so). Wired LAN
   devices -> AX53U LAN ports.
5. Clients reconnect to `b3net` / `b3net-5g` (same SSID+pass) in ~2 min.

## Phase 3 — verify

- Internet wired + both bands.
- DHCP: client gets `192.168.1.100-200`; revo still answers at `.1.2`.
- DNS: a lookup resolves and goes out over DoT (not plaintext :53 to the ISP).
- WireGuard-in: phone on mobile data -> tunnel up -> reach `https://192.168.1.1`
  + resolve a LAN name. DDNS hostname as the WG endpoint.
- No WAN admin / SSH exposed to the internet.

## Phase 4 — rollback

Power off the AX53U; reconnect the old ASUS (ISP -> WAN, devices -> LAN); power
on — old edge back in ~2 min, config untouched. Keep the old router (and the
FreshTomato N18U) on the shelf as backup edges until the AX53U has run clean for
a few days.

### Optional: N18U as a stop-gap edge

Only if you must retire the old router *before* the AX53U is ready (e.g. need the
bench or the box gone): the N18U is already FreshTomato-configured and can take
the edge for a window — but it's **2.4 GHz only** (no `b3net-5g` until the AX53U
lands). Set its LAN `.1.1`, DHCP on, WAN type, Wi-Fi `b3net` 2.4 WPA2, then swap.
Not needed if the old router can stay live until AX53U cutover.

## Open items

- Pick the OpenWrt release for the AX53U + confirm the flash path (recovery vs mtd).
- DDNS hostname for the WG endpoint (dynamic public IP).
- DNS-over-TLS package choice on OpenWrt: `https-dns-proxy` (DoH) vs `stubby` (DoT).
- Decide WPA3 vs WPA2 on the AX53U (Wi-Fi 6 supports WPA3; check old-device compat).
- revo host-key mismatch blocks `ssh revo` (`ssh-keygen -R revo` + re-scan when ready).
