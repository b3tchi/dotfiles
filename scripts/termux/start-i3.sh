#!/bin/bash
# Start i3 in proot Arch with Termux:X11
# Usage: bash ~/.dotfiles/scripts/termux/start-i3.sh
#
# Requires: tur-repo, mesa-zink, virglrenderer-mesa-zink,
#           mesa-vulkan-icd-freedreno, termux-x11-nightly, pulseaudio

DISTRO="archlinux"

# Kill previous sessions
pkill -f termux-x11 2>/dev/null
pkill -f virgl_test_server 2>/dev/null
pkill -f pulseaudio 2>/dev/null
sleep 1

# GPU acceleration (zink-backed virgl for GL 4.3 support)
MESA_LOADER_DRIVER_OVERRIDE=zink \
GALLIUM_DRIVER=zink \
ZINK_DESCRIPTORS=lazy \
  virgl_test_server --use-egl-surfaceless --use-gles &
sleep 2

# Audio
pulseaudio --start \
  --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
  --exit-idle-time=-1 2>/dev/null

# X11 server
termux-x11 :1 &
sleep 2

# Launch i3 inside proot Arch
proot-distro login "$DISTRO" \
  --shared-tmp \
  --bind "$HOME/.dotfiles:/root/.dotfiles" \
  -- bash -c '
  export DISPLAY=:1
  export PULSE_SERVER=tcp:127.0.0.1:4713
  export GALLIUM_DRIVER=virpipe
  export MESA_GL_VERSION_OVERRIDE=4.3
  export MESA_GLES_VERSION_OVERRIDE=3.2

  # Remap Alt to Mod4 (Super) for i3 keybindings
  xmodmap -e "remove mod1 = Alt_L" -e "add mod4 = Alt_L"

  dbus-launch --exit-with-session i3
'
