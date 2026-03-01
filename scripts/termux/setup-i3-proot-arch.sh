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
PROOT_USER="jan"

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
  mesa-vulkan-icd-freedreno

# Install Arch if not present
if ! proot-distro login "$DISTRO" -- true &>/dev/null; then
  echo "Installing Arch Linux in proot..."
  proot-distro install "$DISTRO"
fi

# =========================================================
# PROOT ARCH SIDE (as root)
# =========================================================
echo "=== Setting up i3 inside proot Arch ==="

proot-distro login "$DISTRO" \
  --shared-tmp \
  --bind "$DOTFILES:/root/.dotfiles" \
  -- bash -c '
  PROOT_USER="'"$PROOT_USER"'"

  # Refresh package DB and update
  pacman -Syy --noconfirm
  pacman -Syu --noconfirm

  # i3 + core desktop + kitty terminal
  pacman -S --needed --noconfirm \
    i3-wm i3status i3lock \
    xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xmodmap \
    mesa sudo \
    kitty \
    polybar \
    rofi dmenu \
    picom \
    dunst \
    feh \
    xterm \
    tmux \
    ttf-iosevka-nerd ttc-iosevka \
    dbus git unzip curl

  # neovim + development tools
  pacman -S --needed --noconfirm \
    neovim gcc nodejs npm ripgrep fd lazygit \
    make wget base-devel automake autoconf python

  # Build alttab from source (not in official repos)
  if ! command -v alttab &>/dev/null; then
    echo "Building alttab..."
    pacman -S --needed --noconfirm libpng libxft uthash libxpm
    cd /tmp
    rm -rf alttab
    git clone https://github.com/sagb/alttab.git
    cd alttab
    autoreconf -fi
    ./configure
    make -j4
    make install
    cd /
    rm -rf /tmp/alttab
  fi

  # Install rotz (dotfile manager)
  if ! command -v rotz &>/dev/null; then
    echo "Installing rotz..."
    curl -L https://github.com/volllly/rotz/releases/latest/download/rotz-aarch64-unknown-linux-musl.zip -o /tmp/rotz.zip
    unzip -o /tmp/rotz.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/rotz
    rm /tmp/rotz.zip
  fi
  echo "rotz $(rotz --version)"

  # --- Create user ---
  if ! id "$PROOT_USER" &>/dev/null; then
    echo "Creating user $PROOT_USER..."
    useradd -m -G wheel -s /bin/bash "$PROOT_USER"
  fi

  # Set passwords (required for sudo to work in proot)
  printf "%s\n%s\n" "$PROOT_USER" "$PROOT_USER" | passwd "$PROOT_USER"
  printf "%s\n%s\n" "$PROOT_USER" "$PROOT_USER" | passwd root

  # Fix sudo for proot (setuid bit + explicit sudoers entry)
  chmod u+s /usr/sbin/sudo
  sed -i "s/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/" /etc/sudoers
  echo "$PROOT_USER ALL=(ALL:ALL) ALL" > /etc/sudoers.d/$PROOT_USER
  chmod 440 /etc/sudoers.d/$PROOT_USER

  # --- Link dotfiles for user ---
  USER_HOME="/home/$PROOT_USER"

  # i3
  mkdir -p "$USER_HOME/.i3"
  ln -sf "$USER_HOME/.dotfiles/i3/config" "$USER_HOME/.i3/config"
  rm -f "$USER_HOME/.config/i3/config"

  # kitty
  mkdir -p "$USER_HOME/.config/kitty"
  ln -sf "$USER_HOME/.dotfiles/kitty/kitty.conf" "$USER_HOME/.config/kitty/kitty.conf"
  ln -sf "$USER_HOME/.dotfiles/kitty/tokyonight_night.conf" "$USER_HOME/.config/kitty/tokyonight_night.conf"

  # polybar
  mkdir -p "$USER_HOME/.config/polybar"
  ln -sf "$USER_HOME/.dotfiles/i3/config.ini" "$USER_HOME/.config/polybar/config.ini"
  ln -sf "$USER_HOME/.dotfiles/i3/launch.sh" "$USER_HOME/.config/polybar/launch.sh"
  ln -sf "$USER_HOME/.dotfiles/i3/scripts" "$USER_HOME/.config/polybar/scripts"

  # neovim
  mkdir -p "$USER_HOME/.config/nvim/lua" "$USER_HOME/.local/share/nvim"
  ln -sf "$USER_HOME/.dotfiles/nvim/init.lua" "$USER_HOME/.config/nvim/init.lua"
  ln -sf "$USER_HOME/.dotfiles/nvim/global.markdownlint-cli2.yaml" "$USER_HOME/.config/nvim/global.markdownlint-cli2.yaml"
  ln -sf "$USER_HOME/.dotfiles/nvim/config" "$USER_HOME/.config/nvim/lua/config"
  ln -sf "$USER_HOME/.dotfiles/nvim/plugins" "$USER_HOME/.config/nvim/lua/plugins"

  # Install opencode
  if [ ! -f "$USER_HOME/.opencode/bin/opencode" ]; then
    su - "$PROOT_USER" -c "curl -fsSL https://opencode.ai/install | bash"
  fi
  # Add opencode to PATH in bashrc
  if ! grep -q opencode "$USER_HOME/.bashrc" 2>/dev/null; then
    echo "export PATH=\$HOME/.opencode/bin:\$PATH" >> "$USER_HOME/.bashrc"
  fi

  # Fix ownership
  chown -R "$PROOT_USER:$PROOT_USER" "$USER_HOME"

  # Rebuild font cache
  fc-cache -fv > /dev/null 2>&1

  echo "=== proot Arch setup complete ==="
  echo "User: $PROOT_USER  Password: $PROOT_USER"
'

echo ""
echo "=== Done! ==="
echo ""
echo "User:     $PROOT_USER"
echo "Password: $PROOT_USER  (default is same as username)"
echo "To change: proot-distro login $DISTRO -- passwd $PROOT_USER"
echo ""
echo "To start i3:"
echo "  bash ~/.dotfiles/scripts/termux/start-i3.sh"
echo ""
echo "Then switch to the Termux:X11 app."
