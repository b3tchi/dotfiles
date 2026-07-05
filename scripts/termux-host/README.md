# Termux-host scripts (tracked copies)

These run on the **Termux side** (not inside proot). Live locations in
Termux home (`/data/data/com.termux/files/home`, bind-mounted at `~/termux`
from inside proot):

| tracked copy      | live location            |
|-------------------|--------------------------|
| `start-xrdp.sh`   | `~/start-xrdp.sh`        |
| `stop-xrdp.sh`    | `~/stop-xrdp.sh`         |
| `vnc-xstartup`    | `~/.vnc/xstartup`        |
| `fix-env.sh`      | `~/fix-env.sh`           |

These belong to the older **Xvnc-bridge** stack (xrdp → Xvnc :2/5902,
VNC-password auth, no sesman). The current native-Xorg stack is
`scripts/termux/xorg-rdp.sh` + `start-xorg-rdp-proot.sh`.

No auto-deploy (Termux side has no rotz). After editing here, copy back:

```sh
cp scripts/termux-host/start-xrdp.sh ~/termux/start-xrdp.sh
cp scripts/termux-host/vnc-xstartup  ~/termux/.vnc/xstartup
```
