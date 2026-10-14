{ ... }: {
  # HP EliteDesk — builder, binary cache, main services
  imports = [ ./hardware-configuration.nix ];
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.loader.systemd-boot.enable = true;       # UEFI
  boot.loader.efi.canTouchEfiVariables = true;

  # Build aarch64 (Pi) closures via emulation
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Binary cache for the other hosts
  # services.harmonia = { enable = true; signKeyPaths = [ "/var/lib/secrets/cache-priv.pem" ]; };
  # networking.firewall.allowedTCPPorts = [ 5000 ];
}
