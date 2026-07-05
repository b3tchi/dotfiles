# Termux-host scripts (tracked copies)

These run on the **Termux side** (not inside proot). Termux home
(`/data/data/com.termux/files/home`) is bind-mounted at `~/termux` from
inside proot.

| tracked copy        | live location                  | purpose                          |
|---------------------|--------------------------------|----------------------------------|
| `fix-env.sh`        | `~/fix-env.sh`                 | TMPDIR fix for Termux env        |
| `bashrc-termux`     | `~/.bashrc`                    | TMPDIR + `claude` proot alias    |
| `colors.properties` | `~/.termux/colors.properties`  | Tokyo Night terminal palette     |

Not tracked: `~/.termux/termux.properties` (all-default), `font.ttf` (binary,
re-download), `~/.vnc/passwd` (secret).

Note: the dotfiles repo itself is **bind-shared** between Termux home and the
proot (`~/termux/.dotfiles` = `/home/jan/.dotfiles`, same directory) — one
checkout serves both sides, no sync needed.

The RDP desktop is the native-Xorg stack: `scripts/termux/xorg-rdp.sh`
(Termux-side manager) + `scripts/termux/start-xorg-rdp-proot.sh` (in-proot
stack). The legacy Xvnc-bridge stack (xrdp → Xvnc :2/5902, VNC-password
auth) was pruned 2026-07-05; recover from git history if ever needed.

No auto-deploy (Termux side has no rotz). After editing here, copy back:

```sh
cp scripts/termux-host/fix-env.sh ~/termux/fix-env.sh
```
