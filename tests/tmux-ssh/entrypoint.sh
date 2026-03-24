#!/bin/bash
# Setup SSH keys from shared volume, then start sshd
set -e

SSH_DIR=/home/testuser/.ssh
KEYS_DIR=/shared-keys

# First container to start generates keys into shared volume
if [ ! -f "$KEYS_DIR/id_ed25519" ]; then
    cp /tmp/id_ed25519 "$KEYS_DIR/id_ed25519"
    cp /tmp/id_ed25519.pub "$KEYS_DIR/id_ed25519.pub"
fi

# Wait briefly for keys to appear (in case other container is generating)
for i in $(seq 1 10); do
    [ -f "$KEYS_DIR/id_ed25519" ] && break
    sleep 0.5
done

# Copy keys into user's .ssh
cp "$KEYS_DIR/id_ed25519" "$SSH_DIR/id_ed25519"
cp "$KEYS_DIR/id_ed25519.pub" "$SSH_DIR/id_ed25519.pub"
cp "$KEYS_DIR/id_ed25519.pub" "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/id_ed25519"
chmod 644 "$SSH_DIR/id_ed25519.pub" "$SSH_DIR/authorized_keys"
chown -R testuser:testuser "$SSH_DIR"

exec /usr/sbin/sshd -D
