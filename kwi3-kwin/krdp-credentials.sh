#!/bin/sh
# krdp-credentials.sh - create what krdpserver needs to serve the kwi3-kwin
# session: a self-signed TLS pair and an RDP password. No root. Idempotent: it
# never replaces a file that exists, so a client's trust in the certificate and
# the saved password both survive a redeploy. deploy-kwin-host.sh runs it.
#
#   ~/.local/share/krdp/krdp.crt, krdp.key
#   ~/.config/krdp/password
#
# Same paths as kwi3's krdp-launch.sh. Read the password with:
#   cat ~/.config/krdp/password
# To change it, edit that file and restart the session.
set -eu

umask 077
SHARE=$HOME/.local/share/krdp
CONFIG=$HOME/.config/krdp
mkdir -p "$SHARE" "$CONFIG"

if [ ! -s "$SHARE/krdp.key" ] || [ ! -s "$SHARE/krdp.crt" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=$(cat /etc/hostname 2>/dev/null || echo kwi3-kwin)" \
        -keyout "$SHARE/krdp.key" -out "$SHARE/krdp.crt" 2>/dev/null
    echo "krdp: wrote $SHARE/krdp.crt and krdp.key"
fi

if [ ! -s "$CONFIG/password" ]; then
    openssl rand -base64 18 >"$CONFIG/password"
    echo "krdp: wrote $CONFIG/password"
fi
