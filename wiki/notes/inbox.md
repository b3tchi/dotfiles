# Inbox

Quick captures. Process and move into proper notes.

- 
- 2026-08-03 — xrdp cert rotation. Two RDP stacks, neither has a rotation
  story:
  - `xrdp` (port 3391, `xrdp/dot.yaml`) — TLS deliberately not configured:
    `security_layer=negotiate` + bundled distro key. Comment says add cert +
    `security_layer=tls` before exposing wider than localhost/trusted LAN.
    Now reachable from LAN (ufw allows 192.168.1.0/24 → 3389), so "wider"
    may already be true.
  - `gnome-rdp` (port 3390, `gnome-rdp/dot.yaml:36`) — self-signed
    `openssl req -x509 -days 3650` into `~/.local/share/gnome-remote-desktop`,
    guarded by `[ -f "$GRD_DIR/tls.crt" ] ||` so it is generated once and
    never renewed. 10y lifetime = rotation deferred, not solved.
  - Open: who rotates, on what trigger, and does rotation need a restart of
    `gnome-rdp-session` / xrdp? Related: [[adr0004]], [[im005]], [[sp007]],
    [[poc004]].
- 2026-08-03 — xrdp cert rotation. `xrdp/dot.yaml:14-15` records TLS as
  deliberately unconfigured (`security_layer=negotiate`, bundled key) — OK for
  localhost/trusted LAN, with "add cert + `security_layer=tls`" left as the open
  follow-up. Rotation question sits on top of that: who issues the cert, where it
  lives, how it gets replaced without breaking the meta-wsl-i3 session (xrdp port
  3391) or the GNOME RDP session (3390, `im005`). Related: `adr0004` (i3 over
  xrdp). TODO on processing: fill in the actual trigger/details — captured thin.
