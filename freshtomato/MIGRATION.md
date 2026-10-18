# Router migration plan

Replace the old ASUS edge router with two FreshTomato boxes: the RT-AC66U B1 as
the new dual-band edge, the RT-N18U as a 2.4 GHz access point. Keep the existing
`192.168.1.0/24` subnet so nothing with a hardcoded IP breaks.

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

## Phase 1 — bench-prep the B1 (no downtime; old router stays live)

Same proven flow as the N18U, over the USB-ethernet bench link:
1. Connect B1 LAN port -> laptop USB-ethernet; `nmcli con up asus-lan`.
2. Flash `freshtomato-RT-AC66U_B1-K26ARM-2026.4-VPN-64K.trx` (reset-to-defaults).
3. Reach it (subnet-clash host-route trick if needed); set a temp LAN, e.g. `192.168.2.1`.
4. Set admin password; enable SSH (key in Authorized Keys); HTTPS-only.
5. Push `setup-core.sh` (edit `LAN_IP` — keep `192.168.2.1` for the bench).
6. Wi-Fi in GUI: `b3net-5g` on 5 GHz + `b3net` on 2.4 GHz (WPA2-AES, real password).
   (B1 keeps its own 2.4 only until the N18U takes 2.4 over — then disable B1 2.4.)
7. WireGuard in GUI: `wg0` server, `10.22.0.1/24`, port `51820`, split tunnel;
   add peers (phone QR, laptop config). DNS push `192.168.1.1`.
   Reuse ONE server key here; peers won't need re-pairing later.
8. WAN: set the type from Phase 0 (don't connect WAN cable yet).

## Phase 2 — bench-prep the N18U (already mostly done)

- Core config already applied.
- GUI: Wi-Fi `b3net` 2.4 GHz, WPA2-AES, channel 1. (Currently OPEN — must fix.)
- Leave `ap-mode.sh` UNAPPLIED until cutover (it drops the bench link).

## Phase 3 — cutover (the downtime window, ~a few minutes is fine)

Single edge/DHCP on the LAN at a time. Clean swap:

1. (optional) Shut down revo cleanly so it isn't mid-write during the drop.
2. Set the B1's LAN to `192.168.1.1` (from the bench `.2.1`), reboot.
3. **Power off the old ASUS** (kills its DHCP + Wi-Fi).
4. Move the **ISP/WAN cable** -> B1 **WAN** port. MAC-clone if Phase 0 said so.
5. Move existing wired LAN devices -> B1 **LAN** ports.
6. Cable **N18U LAN -> B1 LAN** port. Apply `ap-mode.sh` to the N18U
   (-> `192.168.1.3`, DHCP off). Confirm its 2.4 `b3net` WPA2 is set.
7. On the B1, add the static lease reserving `.1.3` for the N18U MAC;
   disable the B1's own 2.4 radio (N18U owns 2.4 now).
8. Clients reconnect to `b3net` / `b3net-5g` (same SSID+pass) within ~2 min.

## Phase 4 — verify

- Internet from a wired client and from each band.
- DHCP: a client gets `192.168.1.100-200`; revo still answers at `.1.2`.
- DNS: `nslookup dnssec.works` resolves (DoT path works with a real WAN now).
- Both SSIDs present; 2.4 served by N18U, 5 GHz by B1.
- WireGuard-in: phone on mobile data -> tunnel up -> reach `https://192.168.1.1`
  and resolve a LAN name. Set DDNS + use the hostname as the WG endpoint.
- Confirm no WAN admin exposed (remote_management / remote_mgt_https = 0).

## Phase 5 — rollback (if the swap goes wrong)

1. Power off the B1.
2. Reconnect the old ASUS: ISP cable -> its WAN, LAN devices -> its LAN ports.
3. Power it on — back to the old edge in ~2 min (its config was untouched).

Keep the old router configured and on the shelf until the new setup has run
clean for a few days.

## Open items

- DDNS hostname for the WG endpoint (public IP is dynamic).
- Decide whether the N18U keeps the GUI-made WG server (AP mode doesn't use it)
  or it's removed; WG lives on the B1 regardless.
- revo host-key mismatch blocks `ssh revo` (`ssh-keygen -R revo` + re-scan when ready).
