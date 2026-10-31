# thinclient — HP Compaq Mini 311 RDP client

Boot straight into a fullscreen RDP session menu. No credentials stored on
the device: xrdp shows its own login, KRDP (NLA) prompts in the xterm.

## Device: mini311

| | |
|---|---|
| Model | HP Compaq Mini 311 netbook, battery dead (mains only) |
| CPU | Intel Atom N270, i686 only (no 64-bit) |
| RAM | 1 GB (864 MB usable, rest shared with GPU) |
| GPU | NVIDIA ION / GeForce 9400M — nouveau KMS, Xorg modesetting + glamor (GL 3.3) |
| Panel | 1366x768 |
| Disk | WD Green 120 GB SATA SSD (`/dev/sda`) |
| NIC | NVIDIA MCP79, `forcedeth`, MAC `00:26:9e:50:62:88` |
| Firmware | legacy BIOS, no UEFI. F9 = boot menu, F12 = network boot |
| Hostname / IP | `mini311`, DHCP pool (last seen 192.168.1.117), no reservation yet |
| Access | `ssh root@<ip>` with fleet key `jan@pc`; root password locked (`*`) |

## Current install: Alpine 3.24 x86 (since 2026-10-26)

`setup-disk -m sys` layout: sda1 `/boot` (extlinux), sda2 1 GB swap, sda3 `/`.
Boots power-on → RDP menu in ~20 s (kernel to xterm), ~70 MB RAM idle.

Boot chain: extlinux (hidden, 0.1 s) → OpenRC → busybox init
`tty1::respawn:/bin/login -f rdp` → `~/.bash_profile` → `startx` (rootless:
tty owner + `video`/`input` groups, udev for libinput) → `xinitrc` loops an
xterm running `rdp-pick` → `xfreerdp3`.

Previously Debian 12 i386 (`setup.sh`, `preseed.cfg`, `pxe-serve.sh`) —
same menu files, kept as a fallback recipe.

## Files

| File | Use |
|---|---|
| `rdp-pick`, `xinitrc`, `bash_profile` | shared session files (FreeRDP 2 or 3 auto-detected) |
| `alpine/build-netboot.sh` | stage diskless Alpine PXE boot (RAM, sshd + key) |
| `alpine/setup.sh` | thin-client config for Alpine (RAM test or disk) |
| `setup.sh`, `preseed.cfg`, `pxe-serve.sh`, `mirror-proxy.py` | Debian route |

## Reinstall (Alpine)

1. `alpine/build-netboot.sh 192.168.1.60`, then run the printed HTTP server
   and sudo `dnsmasq` proxyDHCP commands on swift (Wi-Fi LAN, not the
   NM `pi-share` link — Docker's FORWARD DROP breaks its NAT).
2. Mini: F12. TFTP of kernel+initramfs over Wi-Fi takes 3–5 min.
3. `ssh root@<ip>`, `ERASE_DISKS=/dev/sda setup-disk -m sys -s 1024 /dev/sda`.
4. Before reboot: copy `/root/.ssh/authorized_keys` into sda3 and set
   `root:*` in its `/etc/shadow` (netboot root has an empty password).
5. Reboot, copy `rdp-pick xinitrc bash_profile alpine/setup.sh` over, run
   `./setup.sh '192.168.1.60:3392 /rfx' 'nothing-spacewar.lan:3389 /gfx /u:jan'`.

The RAM test can't hold Xorg comfortably: modloop (242 MB) + mesa/LLVM
overflow the default tmpfs; `mount -o remount,size=640M /` gets it running.

## Targets and codecs

| Target | Server | Codec | Feel on the Atom |
|---|---|---|---|
| `192.168.1.60:3392 /rfx` | swift xrdp, kwi3 session | RemoteFX | smooth |
| `nothing-spacewar.lan:3389 /gfx /u:jan` | phone KRDP, 1366x768 virtual KWin | H.264 (only codec KRDP has) | OK, heavier: software decode ~50% CPU |

No hardware video decode: ION's VP needs NVIDIA firmware under nouveau, and
FreeRDP doesn't use VDPAU. Sound is not set up yet (no `/sound`, no ALSA).

## Lessons

- Don't restart getty on tty1 while X runs (VT-switch storm, black screen) — reboot.
- Netboot apkovl must list every runlevel incl. `modloop` in sysinit, or no
  modules (and no SSD) appear.
- Overlay tar root must be mode 755, or non-root users lose access to `/`.

Open work: bd label `mini311`.
