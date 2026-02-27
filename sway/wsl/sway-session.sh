#!/bin/bash
export HOME=/home/jan
export XDG_SESSION_DESKTOP=sway
export XDG_SESSION_TYPE=wayland
export XDG_RUNTIME_DIR=/run/user/0/
export WAYLAND_DISPLAY=wayland-0
export LANG=en_US.UTF-8

LOG="/tmp/sway-session.log"
DESIRED_OUTPUTS=2  # 1 for user + 1 hidden keepalive

log() {
  echo "$(date): $*" | tee -a "$LOG"
}

if [[ ! -e /run/user/0/bus ]]; then
  while ! systemctl restart user@0; do
    :
  done
  while [[ ! -e /run/user/0/bus ]]; do
    log "Waiting for systemd..."
    sleep 1
  done
fi

setup_wslg() {
  umount /tmp/.X11-unix 2>/dev/null
  rm -rf /tmp/.X11-unix
  chmod 700 /run/user/0/
  mkdir -p /tmp/.X11-unix
  chmod 01777 /tmp/.X11-unix
  ln -sf /mnt/wslg/runtime-dir/wayland-0 /run/user/0/wayland-0
  ln -sf /mnt/wslg/runtime-dir/wayland-0.lock /run/user/0/wayland-0.lock
}

# Count active sway outputs
count_outputs() {
  local swaysock="$1"
  SWAYSOCK="$swaysock" swaymsg -t get_outputs 2>/dev/null \
    | grep -c '"name"'
}

# Monitor outputs and maintain the desired count.
# When a window is closed from the taskbar, an output disappears.
# We immediately create a replacement to keep sway alive and connected.
watch_outputs() {
  local sway_pid="$1"
  local swaysock="/run/user/0/sway-ipc.0.${sway_pid}.sock"

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
      # All outputs gone - WSLg fully disconnected, nothing we can do
      log "All outputs lost. Sway will exit on its own."
      return
    fi

    if [[ "$current" -lt "$DESIRED_OUTPUTS" ]]; then
      local missing=$(( DESIRED_OUTPUTS - current ))
      log "Output lost (have $current, want $DESIRED_OUTPUTS). Creating $missing replacement(s)..."
      for ((i = 0; i < missing; i++)); do
        SWAYSOCK="$swaysock" swaymsg create_output 2>/dev/null
      done
      # Match new output size and reposition all windows
      sleep 1
      SWAYSOCK="$swaysock" swaymsg output '*' resolution "$(detect_monitors | head -1)" 2>/dev/null
      position_windows
    fi

    sleep 2
  done
}

# Detect Windows monitor resolutions via PowerShell
detect_monitors() {
  local ps="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  "$ps" -Command '
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
      [string]$_.Bounds.Width + "x" + [string]$_.Bounds.Height
    }
  ' 2>/dev/null | tr -d '\r' | grep -v '^$'
}

# Set sway output resolutions to match Windows monitors
apply_monitor_config() {
  local swaysock="$1"
  local resolutions
  mapfile -t resolutions < <(detect_monitors)

  if [[ ${#resolutions[@]} -eq 0 ]]; then
    log "Could not detect Windows monitors"
    return
  fi

  # Set all outputs to primary monitor resolution
  log "Setting all outputs to ${resolutions[0]}"
  SWAYSOCK="$swaysock" swaymsg output '*' resolution "${resolutions[0]}" 2>/dev/null
}

# Move all WSLg RAIL windows to 0,0 on the Windows desktop
position_windows() {
  local ps="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  "$ps" -Command '
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinPos {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$msrdcPids = @((Get-Process -Name msrdc -ErrorAction SilentlyContinue).Id)
[WinPos]::EnumWindows({param($hWnd, $lParam)
    $procId = [uint32]0
    [WinPos]::GetWindowThreadProcessId($hWnd, [ref]$procId)
    if ($msrdcPids -contains $procId -and [WinPos]::IsWindowVisible($hWnd)) {
        $sb = New-Object System.Text.StringBuilder(256)
        [WinPos]::GetClassName($hWnd, $sb, 256)
        if ($sb.ToString() -eq "RAIL_WINDOW") {
            $rect = New-Object WinPos+RECT
            [WinPos]::GetWindowRect($hWnd, [ref]$rect)
            $w = $rect.Right - $rect.Left
            $h = $rect.Bottom - $rect.Top
            [WinPos]::MoveWindow($hWnd, 0, 0, $w, $h, $true)
        }
    }
    return $true
}, [IntPtr]::Zero) | Out-Null
' 2>/dev/null
  log "Positioned WSLg windows to 0,0"
}

setup_wslg
sway &
SWAY_PID=$!
log "Sway started (PID: $SWAY_PID)"

sleep 2
SWAYSOCK="/run/user/0/sway-ipc.0.${SWAY_PID}.sock"

# Apply detected monitor resolutions
apply_monitor_config "$SWAYSOCK"

# Create the keepalive output(s)
for ((i = 1; i < DESIRED_OUTPUTS; i++)); do
  SWAYSOCK="$SWAYSOCK" swaymsg create_output 2>/dev/null
done

# Position WSLg windows at top-left of screen
sleep 1
position_windows

watch_outputs "$SWAY_PID" &
WATCH_PID=$!

wait $SWAY_PID
kill "$WATCH_PID" 2>/dev/null
wait "$WATCH_PID" 2>/dev/null
log "Sway exited."
