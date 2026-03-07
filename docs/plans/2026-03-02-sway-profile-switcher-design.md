# Sway WSL Profile Switcher

## Goal

Switch between named monitor profiles (office, laptop, home-office) at runtime in a WSL sway session. Each profile sets the sway output resolution to match the target monitor.

## Profiles

Defined in `sway/profiles.yaml`, linked to `~/.config/sway/profiles.yaml`:

```yaml
office:
  resolution: "2560x1440"
laptop:
  resolution: "1920x1200"
home-office:
  resolution: "3840x2160"
```

## Usage

```
sway-profile              # list profiles, show active
sway-profile office       # switch to 2560x1440
sway-profile laptop       # switch to 1920x1200
sway-profile home-office  # switch to 3840x2160
```

After switching, use **Win+Shift+Arrow** to move the RAIL windows to the target Windows display.

## Components

### `sway/profiles.yaml`

YAML file with profile name as key and `resolution` as value.

### `sway/scripts/sway-profile.nu`

Nushell script linked to `~/.local/bin/sway-profile`.

- Reads profiles from `~/.config/sway/profiles.yaml`
- Applies resolution via `swaymsg output '*' resolution <res>`
- Lists profiles with active marker when called without arguments

### `sway/dot.yaml`

Links profiles.yaml and sway-profile.nu (WSL-conditional).

## Design decisions

### Why not move RAIL windows via Win32 API?

WSLg maps mouse input coordinates through its internal RDP monitor layout, not through Win32 window positions. Moving RAIL windows with `SetWindowPos` changes their visual position but breaks mouse input — keyboard works but clicks hit wrong coordinates. This is a fundamental WSLg/RDP limitation.

### Why not use FancyWM for window placement?

FancyWM must have `RAIL_WINDOW` in `ClassIgnoreList`. Without this, FancyWM continuously repositions RAIL windows back to its own tiling layout, overriding any programmatic moves. With RAIL_WINDOW ignored, FancyWM's `MoveToDisplay` action has no effect on them.

### Window placement workflow

Windows native **Win+Shift+Arrow** correctly moves RAIL windows between displays because it goes through the proper Windows display system, which WSLg's RDP input mapping respects. This is the recommended way to move sway windows between monitors.

### Keyboard layout

Sway uses US qwerty (`xkb_layout "us"`) for all keyboards. WSLg merges all physical keyboards into a single RDP input device, so per-device layout switching (e.g. dvorak on laptop, qwerty on external) is not possible from the sway side.
