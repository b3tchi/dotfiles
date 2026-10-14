{ config, pkgs, lib, hostName, ... }:
let
  nas = "192.168.1.245";            # ASUSTOR AS1102TL (reserve this IP in DHCP)
  exportBase = "/volume1/nixos";    # per-host shared folders: ${exportBase}-<host> (ADM NFS is per share)
  mnt = "/etc/nixos-remote";
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

  # Pull: rebuild only when the published version changed.
  systemd.services.nixos-pull = {
    description = "Apply config from NFS if changed";
    path = with pkgs; [ coreutils nix config.system.build.nixos-rebuild ];
    serviceConfig.Type = "oneshot";
    script = ''
      cur=$(readlink ${mnt}/current) || { echo "no export"; exit 0; }
      last=$(cat /var/lib/nixos-pull/version 2>/dev/null || true)
      [ "$cur" = "$last" ] && exit 0
      nixos-rebuild switch --flake "path:${mnt}/current#default"
      mkdir -p /var/lib/nixos-pull && echo "$cur" > /var/lib/nixos-pull/version
    '';
  };
  systemd.timers.nixos-pull = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "10min"; Persistent = true; };
  };

  system.stateVersion = "26.05";    # set once at install, then never change
}
