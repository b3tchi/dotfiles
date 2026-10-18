# Router migration plan

Replace the old ASUS edge router with two FreshTomato boxes: the RT-AC66U B1 as
the new dual-band edge, the RT-N18U as a 2.4 GHz access point. Keep the existing
`192.168.1.0/24` subnet so nothing with a hardcoded IP breaks.

Staged: the N18U takes the edge role first (interim), which frees the old router
and the bench so the B1 can be flashed and configured without time pressure;
a second cutover then makes the B1 the edge and the N18U an AP. See the phases.

## Current state (2026-10)

| Device | Role | Addr | Notes |
|---|---|---|---|
| old ASUS | edge | `192.168.1.1` | `b3net` 2.4 + `b3net-5g` 5 GHz, DHCP for LAN |
| revo | NixOS host | `192.168.1.2` | nix-fleet box |
| RT-N18U | bench | `192.168.2.1` | FreshTomato 2026.4, core config done, WG server keyed (no peers) |
| RT-AC66U B1 | stock, untouched | — | to become edge |
| laptop | — | `192.168.1.60` (wifi) | USB-ethernet bench link to the N18U |

Public IP `78.44.49.38` — routable (not CGNAT), so WireGuard-in is viable.

## Target state

| Device | Role | LAN IP | Wi-Fi | DHCP |
|---|---|---|---|---|
| **B1** | edge | `192.168.1.1` | `b3net-5g` (5 GHz) | server: dynamic `.100-.200`, statics `.2-.50` |
| **N18U** | AP (bridged) | `192.168.1.3` | `b3net` (2.4 GHz) | off |
| old ASUS | retired | — | — | — |

- Edge does WAN + DHCP + DNS (DoT/DNSSEC) + WireGuard-in.
- Band split: 5 GHz on the B1, 2.4 GHz on the N18U, one subnet, clients pick by band.
- `.1.2` stays revo; N18U AP reserved at `.1.3` by MAC `38:2C:4A:65:19:40`.

## Phase 0 — capture the old router's settings (before touching anything)

From the old router's admin UI, write down:
- WAN type (DHCP / PPPoE / static). If PPPoE: username + password.
- WAN MAC (for MAC-clone, if the ISP binds to it).
- Wi-Fi: exact SSIDs (`b3net`, `b3net-5g`), password, security (WPA2-AES).
- Any port forwards / static leases / DDNS hostname to recreate.

Strategy: the **N18U goes live as an interim edge first**. That retires the old
router and frees the bench (USB-ethernet link), so the B1 can be flashed and
configured unhurried while the N18U carries the live network. A second cutover
then promotes the B1 to edge and demotes the N18U to its final AP role.

Two cutovers, each a ~2 min drop. Reuse ONE WireGuard server key across both so
peer configs never change.

### Interim-edge limitation — no 5 GHz

The N18U is **2.4 GHz only**. While it is the edge, there is **no `b3net-5g`** —
all Wi-Fi is 2.4 GHz `b3net`. 5 GHz returns when the B1 takes over. Accept this
for the interim window, or keep the old router's 5 GHz radio alive briefly as a
dumb AP if the gap matters (adds an SSID-clash risk — simplest is to live
without 5 GHz for the window).

## Phase 1 — N18U to interim edge (cutover #1)

The N18U is already FreshTomato 2026.4 with `setup-core.sh` applied. To make it
edge:
1. GUI: set LAN to `192.168.1.1` (from bench `.2.1`); DHCP on (`.100-.200`).
2. WAN: set the type from Phase 0 (DHCP / PPPoE creds / static). MAC-clone the
   old WAN MAC if the ISP binds to it.
3. Wi-Fi: `b3net` 2.4 GHz, WPA2-AES, real password, channel 1. (Currently OPEN.)
4. WireGuard (optional for the interim): `wg0` server already keyed — add peers
   + DDNS if you want remote admin during the window. Keep that server key for
   the B1 later.
5. Cutover: (optional) shut down revo cleanly. **Power off the old ASUS.** Move
   the ISP/WAN cable -> N18U WAN; wired LAN devices -> N18U LAN ports.
6. Clients reconnect to `b3net` (2.4) in ~2 min. Verify internet + DHCP + DNS.

The old router is now free — keep it configured on the shelf for rollback.

## Phase 2 — bench-prep the B1 (no rush; network is live on the N18U)

Laptop rejoins Wi-Fi (`b3net`); its USB-ethernet bench link is now free for the B1.
1. B1 LAN port -> laptop USB-ethernet; `nmcli con up asus-lan`.
2. Flash `freshtomato-RT-AC66U_B1-K26ARM-2026.4-VPN-64K.trx` (reset-to-defaults).
3. Reach it (host-route trick for the subnet clash); temp LAN `192.168.2.1`.
4. Admin password; SSH key; HTTPS-only.
5. Push `setup-core.sh` (keep `LAN_IP=192.168.2.1` for the bench).
6. Wi-Fi in GUI: `b3net-5g` 5 GHz + `b3net` 2.4 GHz, WPA2-AES.
7. WireGuard in GUI: `wg0` server, `10.22.0.1/24`, `51820`, split tunnel, peers,
   DNS push `192.168.1.1`. **Reuse the same server key as the N18U** so peers
   don't re-pair.
8. WAN: set the type (don't connect the WAN cable yet).

## Phase 3 — promote B1 to edge, N18U to AP (cutover #2)

1. Set the B1 LAN to `192.168.1.1`, reboot.
2. **Power off the N18U.** Move ISP/WAN cable -> B1 WAN; LAN devices -> B1 LAN.
3. Bring the N18U back cabled **N18U LAN -> B1 LAN**; apply `ap-mode.sh`
   (-> `192.168.1.3`, DHCP off); confirm its 2.4 `b3net` WPA2.
4. On the B1: reserve `.1.3` for the N18U MAC (static lease); the B1 serves 5 GHz
   `b3net-5g`, the N18U serves 2.4 `b3net` — disable the B1's own 2.4 radio.
5. Clients reconnect to `b3net` / `b3net-5g` in ~2 min. **5 GHz is back.**

## Phase 4 — verify (after each cutover)

- Internet from wired + each available band.
- DHCP: client gets `192.168.1.100-200`; revo still answers at `.1.2`.
- DNS: `nslookup dnssec.works` resolves (DoT works once there's a real WAN).
- After #2: both SSIDs present — 2.4 on N18U, 5 GHz on B1.
- WireGuard-in: phone on mobile data -> tunnel up -> reach `https://192.168.1.1`
  + resolve a LAN name. DDNS hostname as the WG endpoint.
- No WAN admin exposed (`remote_management` / `remote_mgt_https` = 0).

## Phase 5 — rollback (either cutover)

1. Power off the FreshTomato edge (N18U or B1).
2. Reconnect the old ASUS: ISP cable -> its WAN, LAN devices -> its LAN ports.
3. Power on — back to the old edge in ~2 min (its config was untouched).

Keep the old router configured and on the shelf until the final setup has run
clean for a few days.

## Open items

- DDNS hostname for the WG endpoint (public IP is dynamic).
- Decide whether the N18U keeps the GUI-made WG server (AP mode doesn't use it)
  or it's removed; WG lives on the B1 regardless.
- revo host-key mismatch blocks `ssh revo` (`ssh-keygen -R revo` + re-scan when ready).
