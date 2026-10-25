# OpenWrt — RT-AX53U edge

The ASUS RT-AX53U (MediaTek MT7621A, ramips/mt7621, Wi-Fi 6 dual-band) is the
network edge, on OpenWrt. It replaces the old ASUS router and does WAN + DHCP +
DNS + WireGuard-in + both Wi-Fi bands. See `../freshtomato/MIGRATION.md` for the
whole-network plan; the Broadcom boxes are shelved spares.

Why OpenWrt (not FreshTomato): the AX53U is MediaTek, not Broadcom. OpenWrt's
MediaTek Wi-Fi is first-class; FreshTomato/DD-WRT/Merlin don't support the chip.

## Firmware

OpenWrt **25.12.6**, target `ramips/mt7621`, profile `asus_rt-ax53u`.

    https://downloads.openwrt.org/releases/25.12.6/targets/ramips/mt7621/

Images (sha256 in the release `sha256sums`):
- `...-asus_rt-ax53u-squashfs-factory.bin`      — stock -> OpenWrt, via mtd-write
- `...-asus_rt-ax53u-initramfs-kernel.bin`      — recovery step 1 (TFTP/rescue)
- `...-asus_rt-ax53u-squashfs-sysupgrade.bin`   — recovery step 2 / upgrades

## Flash (mtd-write from stock — what was used)

No web-UI flash on this model. From stock ASUS firmware:
1. Finish the setup wizard; Administration -> System -> enable SSH (LAN); paste
   an authorized key. SSH user = the admin username you set (not always `admin`).
2. Stream the factory image to the router and verify:
       ssh <user>@192.168.50.1 'cat > /tmp/owrt.bin' < ...-factory.bin
       ssh <user>@192.168.50.1 'md5sum /tmp/owrt.bin'   # compare to local
3. Flash the Kernel partition (mtd5 "Kernel" on this box):
       ssh <user>@192.168.50.1 'mtd-write -i /tmp/owrt.bin -d Kernel'
4. **Power-cycle (pull the plug)** — do NOT soft-reboot; stock can kernel-panic
   on a graceful reboot after mtd-write.
5. Boots OpenWrt at `192.168.1.1` (root, no password). Reach it over a wired
   port; set a root password in LuCI immediately.

Recovery fallback if it bricks: ASUS Firmware Restoration / TFTP rescue mode —
flash the initramfs-kernel image, then sysupgrade. (NIC static 192.168.1.10,
hold RESET on power-up until the LED blinks, TFTP to 192.168.1.1.)

## Config

OpenWrt uses UCI (`/etc/config/*`, `uci` CLI) — the FreshTomato nvram scripts do
not apply here.

- `setup-base.sh` — LAN, DHCP (`.100-.200`), hostname, timezone, Wi-Fi country.
  Runs with base packages only (no WAN). **Done on the bench.**
- `setup-edge.sh` — `apk add` WireGuard + DNS-over-HTTPS, then configure
  WireGuard-in (`wg0`, `10.22.0.1/24`, port 51820, split tunnel) and DoH. Needs
  internet, so **run after cutover**.

Secrets stay off the repo: the root password and Wi-Fi PSK are set in LuCI; the
WireGuard server private key is generated on the box. Only peer PUBLIC keys go
in `setup-edge.sh`.

OpenWrt 25.12 uses `apk`, not `opkg`.

## As-built (2026-10)

- Edge live: WAN DHCP (`78.44.49.38`), LAN `192.168.1.1`, DHCP `.100-.200`.
- Wi-Fi `b3net` (2.4, radio0) + `b3net-5g` (5, radio1), WPA2-AES, same PSK (set in LuCI).
- DNS over DoH (Cloudflare + Quad9) via https-dns-proxy; names resolve (`nas.lan`, etc.).
- `nas` static-host record -> `192.168.1.245` (NAS has a static IP, no lease to auto-name).
- `swift` DHCP reservation (Acer Swift laptop) -> fixed `192.168.1.60`, resolves `swift.lan`.
- nix-fleet reservations: `revo` -> `.2`, `elitedesk` -> `.99` (pi -> `.6`, MAC TBD).
  Required: the NAS NFS exports are IP-restricted, so these hosts must keep their
  fixed IPs or the NFS config-pull fails `access denied`. See `setup-base.sh`.
- WireGuard-in `wg0` `10.22.0.1/24` :51820; peer `motorola-razr` (`10.22.0.2/32`),
  handshake confirmed. Endpoint is the raw public IP (see DDNS note).
- Lockdown: SSH key-only, HTTPS-only UI, no WAN admin, only UDP 51820 open on wan.

### DDNS (optional, not enabled)

`ddns-scripts` + `luci-app-ddns` are installed but dormant. The public IP has been
stable, so the WireGuard endpoint uses the raw IP. If the IP ever changes you lose
remote access until home — enable DDNS then (LuCI -> Services -> Dynamic DNS;
DuckDNS = subdomain + token) and switch the client Endpoint to the hostname.
