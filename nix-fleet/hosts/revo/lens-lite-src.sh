#!/usr/bin/env bash
# Write lens-lite-src.tar.gz (tdpr/server at the given tdpr rev) next to this
# script and record the rev in lens-lite.rev. The repo b3tchi/tdpr is private
# and revo has no GitHub access, so the source rides to revo via publish.sh.
# Usage: ./lens-lite-src.sh <rev>   (rev must exist in TDPR_REPO)
set -euo pipefail
rev="${1:?usage: $0 <tdpr-rev>}"
repo="${TDPR_REPO:-$HOME/repos/b3tchi/tdpr/main}"
here="$(cd "$(dirname "$0")" && pwd)"
full="$(git -C "$repo" rev-parse --verify "$rev^{commit}")"
# Reproducible: archiving a tree (rev:path) stamps the current time, so pin
# mtimes to the commit time; gzip -n drops the name/time.
git -C "$repo" archive --format=tar --prefix=lens-lite/ \
  --mtime="$(git -C "$repo" log -1 --format=%ct "$full")" "$full:tdpr/server" \
  | gzip -n > "$here/lens-lite-src.tar.gz"
echo "$full" > "$here/lens-lite.rev"
echo "wrote $here/lens-lite-src.tar.gz ($(du -h "$here/lens-lite-src.tar.gz" | cut -f1)) at $full"
echo "next: update vendorHash in lens-lite.nix if go.mod/go.sum changed"
