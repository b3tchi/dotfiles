#!/bin/bash
# Install opencode in proot Arch Linux on Termux
# Usage: bash scripts/termux/opencode-proot-arch.sh

set -e

DISTRO="archlinux"

# Must run from Termux, not inside proot
if [ -f /etc/arch-release ] || [ "$(whoami)" = "root" ]; then
  echo "Error: Run this script from Termux, not inside proot."
  exit 1
fi

# Check proot-distro is available
if ! command -v proot-distro &>/dev/null; then
  echo "Installing proot-distro..."
  pkg install -y proot-distro
fi

# Install Arch if not present
if ! proot-distro login "$DISTRO" -- true &>/dev/null; then
  echo "Installing Arch Linux in proot..."
  proot-distro install "$DISTRO"
fi

echo "Updating Arch and installing opencode..."
proot-distro login "$DISTRO" -- bash -c '
  pacman -Syu --noconfirm curl

  if command -v opencode &>/dev/null; then
    echo "opencode is already installed: $(opencode --version)"
    exit 0
  fi

  curl -fsSL https://opencode.ai/install | bash

  # Add to PATH in bashrc
  OPENCODE_PATH="export PATH=/root/.opencode/bin:\$PATH"
  if ! grep -q ".opencode/bin" /root/.bashrc 2>/dev/null; then
    echo "$OPENCODE_PATH" >> /root/.bashrc
    echo "Added opencode to PATH in /root/.bashrc"
  fi

  export PATH=/root/.opencode/bin:$PATH
  echo "opencode $(opencode --version) installed successfully"
'

echo ""
echo "Done! To use opencode:"
echo "  proot-distro login $DISTRO"
echo "  cd <project>"
echo "  opencode"
