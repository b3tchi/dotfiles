# OVPN — Home LAN access

#ssh #vpn #ovpn

Per-connection VPN: SSH to home LAN triggers OpenVPN tunnel, last SSH closes → tunnel down.

## Topology

```
[device] --internet--> [Asus RT-AC66U_B1 @ b3net.asuscomm.com:1194/UDP] --LAN-- [home boxes]
                              ↓ tun0
                         home LAN 192.168.1.0/24
```

Split tunnel — only LAN routes via tun0, rest of traffic untouched.

## Files

| Path | Purpose |
|---|---|
| `~/vpn/home.ovpn` | OpenVPN client config (0600, contains cert/key) |
| `~/vpn/vpn-up.sh` | ProxyCommand wrapper, idempotent + ref-counted |
| `~/vpn/creds.txt` (or via gopass `vpn/home`) | username/password, 2 lines |
| `/etc/sudoers.d/openvpn-jan` | NOPASSWD for openvpn/kill |
| `~/.ssh/config` `Host home` | ProxyCommand points at `vpn-up.sh` |

## Wrapper behavior

`~/vpn/vpn-up.sh`:

1. Touch refcount file `/tmp/home-vpn.refs/$$`
2. If `/tmp/home-vpn.pid` not alive → `sudo openvpn --daemon --auth-user-pass …` with creds (from gopass tmpfile)
3. Wait until `tun0` link up (15s timeout)
4. `exec nc <host> <port>` → SSH uses as transport
5. On exit (trap): rm refcount; if zero refs → `sudo kill <pid>` + rm creds tmpfile

## SSH config

```
Host home
  Hostname 192.168.1.60
  User jan
  PreferredAuthentications publickey
  IdentityFile ~/.ssh/id_ed25519_to_manjaro
  ProxyCommand ~/vpn/vpn-up.sh %h %p
```

## Outstanding setup steps

```bash
sudo pacman -S openvpn

# gopass entry — two lines: USER\nPASSWORD
gopass init                 # if not yet initialized
gopass insert -m vpn/home

# Passwordless sudo for openvpn (else ssh hangs on prompt mid-ProxyCommand)
sudo tee /etc/sudoers.d/openvpn-jan <<EOF
jan ALL=(root) NOPASSWD: /usr/sbin/openvpn, /usr/bin/kill
EOF
sudo chmod 440 /etc/sudoers.d/openvpn-jan

# Verify before depending on it
ssh home
```

## Cleanup

`/sdcard/Download/bw/client.ovpn` was world-readable on Android shared storage. Already copied to `~/vpn/home.ovpn` (0600). After verifying ssh home works, delete original:

```bash
rm /sdcard/Download/bw/client.ovpn
```

## Caveats

- Cipher `AES-128-CBC` — Asus RT-AC66U firmware limit; OK for home, weak by today's standards
- Server pushes LAN route automatically (Asus "VPN client will use VPN to access: LAN only"). If `ip route` lacks home LAN after connect, add `route 192.168.1.0 255.255.255.0` to `home.ovpn`
- Case B (same dest, parallel VPN/no-VPN sessions) needs network namespace → won't work in proot Termux; only Case A (different destinations) works split-tunnel

## See also

- [[inbox]] for any follow-ups
