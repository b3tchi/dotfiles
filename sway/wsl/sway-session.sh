#!/bin/bash
export HOME=/home/jan
export XDG_SESSION_DESKTOP=sway
export XDG_SESSION_TYPE=wayland
UID_NUM=$(id -u)
export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
export WAYLAND_DISPLAY=wayland-0
export LANG=en_US.UTF-8

LOG="/tmp/sway-session.log"
DESIRED_OUTPUTS=2  # 1 for user + 1 hidden keepalive

log() {
  echo "$(date): $*" | tee -a "$LOG"
}

# Wait for D-Bus session bus (should already exist for user services)
while [[ ! -e "${XDG_RUNTIME_DIR}/bus" ]]; do
  log "Waiting for D-Bus session bus..."
  sleep 1
done

setup_wslg() {
  # Link WSLg Wayland socket into user runtime dir
  ln -sf /mnt/wslg/runtime-dir/wayland-0 "${XDG_RUNTIME_DIR}/wayland-0"
  ln -sf /mnt/wslg/runtime-dir/wayland-0.lock "${XDG_RUNTIME_DIR}/wayland-0.lock"
}

# Count active sway outputs (only counts outputs with "active": true)
count_outputs() {
  local swaysock="$1"
  SWAYSOCK="$swaysock" swaymsg -t get_outputs 2>/dev/null \
    | grep -c '"active": true'
}

# Monitor outputs and maintain the desired count.
# When a window is closed from the taskbar, an output disappears.
# We immediately create a replacement to keep sway alive and connected.
watch_outputs() {
  local sway_pid="$1"
  local swaysock="${XDG_RUNTIME_DIR}/sway-ipc.${UID_NUM}.${sway_pid}.sock"

  sleep 5

  if [[ ! -e "$swaysock" ]]; then
    log "Warning: Sway IPC socket not found at $swaysock"
    return
  fi
  log "Watching outputs via $swaysock (desired: $DESIRED_OUTPUTS)"

  while kill -0 "$sway_pid" 2>/dev/null; do
    local current
    current=$(count_outputs "$swaysock")

    if [[ -z "$current" || "$current" -eq 0 ]]; then
      # All outputs gone - WSLg disconnected, but may reconnect
      log "All outputs lost. Waiting for WSLg to reconnect..."
      sleep 5
    elif [[ "$current" -lt "$DESIRED_OUTPUTS" ]]; then
      local missing=$(( DESIRED_OUTPUTS - current ))
      log "Output lost (have $current, want $DESIRED_OUTPUTS). Creating $missing replacement(s)..."
      for ((i = 0; i < missing; i++)); do
        SWAYSOCK="$swaysock" swaymsg create_output 2>/dev/null
      done
      sleep 2
    else
      sleep 2
    fi
  done
}

# Profile-based resolution: reads from ~/.config/sway/profile
# Profiles: laptop (1920x1200), office (2560x1440), home-office (3840x2160)
get_profile_resolution() {
  local profile_file="${HOME}/.config/sway/profile"
  local profile="laptop"

  if [[ -f "$profile_file" ]]; then
    profile=$(cat "$profile_file" | tr -d '[:space:]')
  fi

  case "$profile" in
    laptop)      echo "1920x1200" ;;
    office)      echo "2560x1440" ;;
    home-office) echo "3840x2160" ;;
    *)           log "Unknown profile '$profile', defaulting to laptop"
                 echo "1920x1200" ;;
  esac
}

apply_monitor_config() {
  local swaysock="$1"
  local res
  res=$(get_profile_resolution)
  log "Profile '$(cat "${HOME}/.config/sway/profile" 2>/dev/null || echo laptop)': setting all outputs to ${res}"
  SWAYSOCK="$swaysock" swaymsg output '*' resolution "${res}" 2>/dev/null
}

setup_wslg
sway &
SWAY_PID=$!
log "Sway started (PID: $SWAY_PID)"

sleep 2
SWAYSOCK="${XDG_RUNTIME_DIR}/sway-ipc.${UID_NUM}.${SWAY_PID}.sock"

# Apply detected monitor resolutions
apply_monitor_config "$SWAYSOCK"

# Create the keepalive output(s)
for ((i = 1; i < DESIRED_OUTPUTS; i++)); do
  SWAYSOCK="$SWAYSOCK" swaymsg create_output 2>/dev/null
done

# Watch profile file for changes and apply resolution immediately
watch_profile() {
  local sway_pid="$1"
  local swaysock="${XDG_RUNTIME_DIR}/sway-ipc.${UID_NUM}.${sway_pid}.sock"
  local profile_file="${HOME}/.config/sway/profile"
  local last_res
  last_res=$(get_profile_resolution)

  while kill -0 "$sway_pid" 2>/dev/null; do
    local current_res
    current_res=$(get_profile_resolution)
    if [[ "$current_res" != "$last_res" ]]; then
      log "Profile changed: applying ${current_res}"
      SWAYSOCK="$swaysock" swaymsg output '*' resolution "${current_res}" 2>/dev/null
      last_res="$current_res"
    fi
    sleep 2
  done
}

watch_outputs "$SWAY_PID" &
WATCH_PID=$!

watch_profile "$SWAY_PID" &
PROFILE_PID=$!

wait $SWAY_PID
SWAY_EXIT=$?
kill "$WATCH_PID" "$PROFILE_PID" 2>/dev/null
wait "$WATCH_PID" "$PROFILE_PID" 2>/dev/null
log "Sway exited (code: $SWAY_EXIT)."
exit $SWAY_EXIT
