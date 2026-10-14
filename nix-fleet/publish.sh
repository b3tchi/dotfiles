#!/usr/bin/env bash
# Publish a new version to each host's NAS share over SSH, then switch atomically.
# Usage: ./publish.sh            (all hosts)
#        ./publish.sh revo pi    (selected hosts)
#
# Each host has its own folder /volume1/nixos-<host> on the NAS, NFS-exported
# read-only to that host. This PC writes to it over SSH (no local mount/sudo).
set -euo pipefail

NAS="${NAS:-b3tchi@192.168.1.245}"
NAS_PORT="${NAS_PORT:-10022}"
NAS_KEY="${NAS_KEY:-$HOME/.ssh/id_nas_b3tchi}"
NAS_BASE="${NAS_BASE:-/volume1/nixos}"        # share = ${NAS_BASE}-<host>
NIX_IMAGE="${NIX_IMAGE:-nixos/nix:2.28.3}"   # used only when nix isn't installed
SRC="$(cd "$(dirname "$0")" && pwd)"
VER="v$(date +%Y%m%d-%H%M%S)"

SSH=(ssh -i "$NAS_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -p "$NAS_PORT")

# Ensure flake.lock exists/pinned. Fall back to a container when nix is absent.
if command -v nix >/dev/null; then
  nix --extra-experimental-features 'nix-command flakes' flake lock "path:$SRC"
else
  docker run --rm -v "$SRC":/src -w /src "$NIX_IMAGE" sh -c \
    "nix --extra-experimental-features 'nix-command flakes' flake lock path:/src \
     && chown $(id -u):$(id -g) /src/flake.lock"
fi

hosts=("$@")
[ ${#hosts[@]} -eq 0 ] && mapfile -t hosts < <(ls "$SRC/hosts")

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

for h in "${hosts[@]}"; do
  share="$NAS_BASE-$h"
  "${SSH[@]}" "$NAS" "test -d '$share' && test -w '$share'" \
    || { echo "✗ $h: $share missing or not writable on NAS, skipping" >&2; continue; }
  echo "→ $h ($VER)"

  # Only this host's folder + shared files: hosts can't see each other.
  d="$stage/$h/$VER"
  mkdir -p "$d/hosts"
  cp "$SRC/flake.nix" "$SRC/flake.lock" "$d/"
  cp -r "$SRC/modules" "$d/modules"
  cp -r "$SRC/hosts/$h" "$d/hosts/$h"
  echo "$h" > "$d/HOST"

  rsync -a -e "${SSH[*]}" "$d" "$NAS:$share/"
  # Atomic switch: relative symlink so it resolves on the host's mount too.
  "${SSH[@]}" "$NAS" "cd '$share' && ln -sfn '$VER' current.tmp && mv -fT current.tmp current && readlink current"
done

echo "Done. Hosts apply within ~10 min. Rollback: ssh to NAS, ln -sfn <older-ver> $NAS_BASE-<host>/current"
