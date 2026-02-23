#!/bin/bash
# Setup i3 desktop in proot Arch Linux with Termux:X11
# Usage: bash ~/.dotfiles/scripts/termux/setup-i3-proot-arch.sh
#
# Prerequisites:
#   - Termux:X11 APK installed on the device
#     https://github.com/termux/termux-x11/releases

set -e

DISTRO="archlinux"
DOTFILES="$HOME/.dotfiles"

# --- Guard: must run from Termux, not proot ---
if [ -f /etc/arch-release ] || [ "$(whoami)" = "root" ]; then
  echo "Error: Run this script from Termux, not inside proot."
  exit 1
fi

# =========================================================
# TERMUX SIDE
# =========================================================
echo "=== Setting up Termux side ==="

pkg update -y
pkg install -y x11-repo tur-repo
pkg install -y termux-x11-nightly pulseaudio proot-distro
pkg install -y mesa-zink virglrenderer-mesa-zink \
  mesa-vulkan-icd-freedreno vulkan-loader-android

# Install Arch if not present
if ! proot-distro login "$DISTRO" -- true &>/dev/null; then
  echo "Installing Arch Linux in proot..."
  proot-distro install "$DISTRO"
fi

# =========================================================
# PROOT ARCH SIDE
# =========================================================
echo "=== Setting up i3 inside proot Arch ==="

proot-distro login "$DISTRO" \
  --shared-tmp \
  --bind "$DOTFILES:/root/.dotfiles" \
  -- bash -c '
  # Refresh package DB and update
  pacman -Syy --noconfirm
  pacman -Syu --noconfirm

  # i3 + core desktop + kitty terminal
  pacman -S --needed --noconfirm \
    i3-wm i3status i3lock \
    xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xmodmap \
    mesa \
    kitty \
    polybar \
    rofi dmenu \
    picom \
    dunst \
    feh \
    xterm \
    ttf-iosevka-nerd ttc-iosevka \
    dbus git unzip curl

  # Install rotz (dotfile manager)
  if ! command -v rotz &>/dev/null; then
    echo "Installing rotz..."
    curl -L https://github.com/volllly/rotz/releases/latest/download/rotz-aarch64-unknown-linux-musl.zip -o /tmp/rotz.zip
    unzip -o /tmp/rotz.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/rotz
    rm /tmp/rotz.zip
  fi
  echo "rotz $(rotz --version)"

  # Link i3 config via rotz
  rotz -d /root/.dotfiles link -f i3

  # Remove default i3 config if it exists
  rm -f ~/.config/i3/config

  # Rebuild font cache
  fc-cache -fv > /dev/null 2>&1

  echo "=== proot Arch setup complete ==="
'

echo ""
echo "=== Done! ==="
echo ""
echo "To start i3:"
echo "  bash ~/.dotfiles/scripts/termux/start-i3.sh"
echo ""
echo "Then switch to the Termux:X11 app."
