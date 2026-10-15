{ config, pkgs, lib, hostName, ... }:
let
  nas = "192.168.1.245";            # ASUSTOR AS1102TL (reserve this IP in DHCP)
  exportBase = "/volume1/nixos";    # per-host shared folders: ${exportBase}-<host> (ADM NFS is per share)
  mnt = "/etc/nixos-remote";
  # Each host takes security fixes on its own: build the NAS config against the
  # newest commit of its stable branch instead of the publisher's pinned lock.
  channel = "github:NixOS/nixpkgs/nixos-${lib.trivial.release}";

  # $1 = "changed": apply only a new published version; "always": rebuild anyway
  # (weekly security run). The flock keeps both timers from running at once.
  apply = pkgs.writeShellScript "nixos-pull-apply" ''
    set -eu
    exec 9>/run/nixos-pull.lock
    flock 9
    cur=$(readlink ${mnt}/current) || { echo "no export"; exit 0; }
    last=$(cat /var/lib/nixos-pull/version 2>/dev/null || true)
    if [ "$1" = changed ] && [ "$cur" = "$last" ]; then exit 0; fi
    # build from the resolved version dir: path: flakes copy a symlink as-is
    nixos-rebuild switch --flake "path:${mnt}/$cur#default" \
      --override-input nixpkgs ${channel} --no-write-lock-file
    mkdir -p /var/lib/nixos-pull && echo "$cur" > /var/lib/nixos-pull/version
  '';
  applyPath = with pkgs; [ coreutils util-linux nix config.system.build.nixos-rebuild ];
in {
  networking.hostName = hostName;
  networking.useDHCP = true;        # IP comes from the MAC reservation; no static IP here

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 14d"; };
  # Optional: EliteDesk binary cache
  # nix.settings.substituters = [ "http://192.168.1.22:5000" ];
  # nix.settings.trusted-public-keys = [ "elitedesk:..." ];

  services.openssh = {
    enable = true;
    settings = { PasswordAuthentication = false; PermitRootLogin = "prohibit-password"; };
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINcXUjXpfDE34noiIXN12NSSUYcwZqsZgqzFrxB5QFFd jan@pc"
  ];

  zramSwap.enable = true;           # helps the Pi/Revo survive evaluation

  # Read-only mount of this host's own export, mounted on demand.
  boot.supportedFilesystems = [ "nfs" ];
  fileSystems.${mnt} = {
    device = "${nas}:${exportBase}-${hostName}";
    fsType = "nfs";
    options = [ "ro" "noauto" "x-systemd.automount" "x-systemd.idle-timeout=600" "nfsvers=4" ];
  };

  # Pull: rebuild when the published version changed.
  systemd.services.nixos-pull = {
    description = "Apply config from NFS if changed";
    # Activation must not restart the unit that is running it (same as system.autoUpgrade).
    restartIfChanged = false;
    path = applyPath;
    serviceConfig = { Type = "oneshot"; ExecStart = "${apply} changed"; };
  };
  systemd.timers.nixos-pull = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "10min"; Persistent = true; };
  };

  # Security: weekly rebuild of the current config against the newest stable
  # nixpkgs, independent of the publisher and of other hosts.
  systemd.services.nixos-security-update = {
    description = "Rebuild current config against newest ${channel}";
    restartIfChanged = false;
    path = applyPath;
    serviceConfig = { Type = "oneshot"; ExecStart = "${apply} always"; };
  };
  systemd.timers.nixos-security-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "weekly"; RandomizedDelaySec = "6h"; Persistent = true; };
  };

  system.stateVersion = "26.05";    # set once at install, then never change
}
