{ ... }: {
  # HP EliteDesk 705 G2 Mini — HTPC only (Kodi; background jobs at low priority)
  imports = [ ./hardware-configuration.nix ../../modules/htpc.nix ];
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.loader.systemd-boot.enable = true;       # UEFI
  boot.loader.efi.canTouchEfiVariables = true;
}
