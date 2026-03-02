#!/usr/bin/env nu

# Sway WSL profile switcher
# Switches monitor resolution for different monitor setups.
# After switching, use Win+Shift+Arrow to snap RAIL windows to the target display.

const PROFILES_PATH = "~/.config/sway/profiles.yaml"

def get-profiles [] {
  open ($PROFILES_PATH | path expand)
}

def get-current-resolution [] {
  swaymsg -t get_outputs
    | from json
    | where active
    | first
    | get current_mode
    | $"($in.width)x($in.height)"
}

# List available profiles, highlighting the active one
def "main --list" [] {
  main
}

# Switch sway to a named monitor profile or list available profiles
def main [
  profile?: string  # Profile name (office, laptop, home-office). Omit to list profiles.
] {
  let profiles = get-profiles

  if ($profile == null) {
    let current_res = get-current-resolution
    let profile_names = $profiles | columns

    print "Available profiles:"
    for name in $profile_names {
      let p = $profiles | get $name
      let marker = if $p.resolution == $current_res { " <-- active" } else { "" }
      print $"  ($name): ($p.resolution)($marker)"
    }
    return
  }

  let profile_names = $profiles | columns
  if $profile not-in $profile_names {
    print $"Error: unknown profile '($profile)'"
    print $"Available: ($profile_names | str join ', ')"
    return
  }

  let p = $profiles | get $profile

  print $"Switching to profile '($profile)': ($p.resolution)"

  # Apply resolution to all sway outputs
  swaymsg $"output '*' resolution ($p.resolution)"
  print "  Resolution applied."
  print "  Use Win+Shift+Arrow to move windows to the target display."
}
