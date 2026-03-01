#!/bin/bash
# Change password for proot Arch Linux user
# Usage: bash ~/.dotfiles/scripts/termux/change-proot-password.sh [username]

DISTRO="archlinux"
USER="${1:-jan}"

echo "Changing password for user '$USER' in proot Arch..."
proot-distro login "$DISTRO" -- passwd "$USER"
