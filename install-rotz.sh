#!/usr/bin/env bash
set -euo pipefail

REPO="volllly/rotz"
# Detect Termux
if [ -d "/data/data/com.termux" ]; then
  INSTALL_DIR="/data/data/com.termux/files/usr/bin"
else
  INSTALL_DIR="${HOME}/.local/bin"
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  TARGET_ARCH="x86_64" ;;
  i686)    TARGET_ARCH="i686" ;;
  aarch64) TARGET_ARCH="aarch64" ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Detect OS and pick target triple
OS=$(uname -s)
case "$OS" in
  Linux)  TARGET="${TARGET_ARCH}-unknown-linux-musl" ;;
  Darwin) TARGET="${TARGET_ARCH}-apple-darwin" ;;
  *)
    echo "Unsupported OS: $OS"
    exit 1
    ;;
esac

ASSET="rotz-${TARGET}.zip"

echo "Installing rotz for ${TARGET}..."

mkdir -p "$INSTALL_DIR"

WORK_DIR=$(mktemp -d "${HOME}/.cache/rotz-install.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

gh release download --repo "$REPO" --pattern "$ASSET" --dir "$WORK_DIR"

unzip -o "$WORK_DIR/$ASSET" -d "$WORK_DIR"

install -m 755 "$WORK_DIR/rotz" "$INSTALL_DIR/rotz"

echo "Installed rotz to ${INSTALL_DIR}/rotz"
rotz --version
