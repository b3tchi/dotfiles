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
- `setup-switch-n18u.sh` — RT-N18U as a dumb wired switch (see below).
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
- nix-fleet reservations: `revo` -> `.2`, `elitedesk` -> `.99` `pi3b` -> `.6`.
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

## RT-N18U switch

The spare RT-N18U (Broadcom BCM4708, `bcm53xx/generic`, profile `asus_rt-n18u`)
runs OpenWrt **25.12.6** as a wired-only switch: `sw-n18u` at `192.168.1.3`,
all 5 ports bridged. Ports: `wan` = uplink -> AX53U LAN, `lan1` = revo,
`lan2` = pi3b, `lan3`/`lan4` free. No Wi-Fi (OpenWrt has no driver
for its radio). Config: `setup-switch-n18u.sh`.

Image: `openwrt-25.12.6-bcm53xx-generic-asus_rt-n18u-squashfs.trx` (starts `HDR0`).

Flash from FreshTomato over SSH (what was used):

    ssh root@192.168.2.1 'cat > /tmp/owrt.trx' < ...-squashfs.trx
    ssh root@192.168.2.1 'md5sum /tmp/owrt.trx'        # compare to local
    ssh root@192.168.2.1 'mtd-write2 /tmp/owrt.trx linux'   # "CRC OK"
    ssh root@192.168.2.1 reboot

It boots at `192.168.1.1` — clashes with the edge. On the bench link, pin that
IP to the USB NIC and source from the laptop's `.1.x` address (OpenWrt has no
route back to a non-`.1.x` source):

    sudo ip route add 192.168.1.1/32 dev <usb-iface>
    ssh -b 192.168.1.60 root@192.168.1.1 ...
    sudo ip route del 192.168.1.1/32 dev <usb-iface>   # after it moves to .3

While pinned, the laptop's DNS (`192.168.1.1`) hits the N18U and breaks — keep
the window short. Afterwards `ssh-keygen -R 192.168.1.1` (N18U key lands there).

### USB + adb host (optional)

The N18U doubles as a USB/adb host on the LAN (dual USB; USB host + Northstar
PHY are built into the bcm53xx image). A **sysupgrade wipes these packages** —
re-add them after any flash:

    ssh root@192.168.1.3
    apk update
    apk add kmod-usb-ohci kmod-usb2 kmod-usb3 \
            kmod-phy-bcm-ns-usb2 kmod-phy-bcm-ns-usb3 kmod-usb-bcma \
            kmod-usb-net-rndis kmod-usb-net-cdc-ncm adb
    reboot      # USB PHY binds on reboot

(The `kmod-usb-*`/PHY names are already in the image, so apk only pulls `adb` +
the usb-net class drivers — harmless to list them all.) Then plug an Android in
(USB debugging ON, tap "Allow" on the RSA prompt) and `adb devices` → `adb shell`.
No routing role — tether-as-WAN is pointless on a dumb switch; adb only.
