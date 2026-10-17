{ ... }: {
  # Acer Revo RL70 — AMD E-450, light services
  imports = [ ./hardware-configuration.nix ];
  nixpkgs.hostPlatform = "x86_64-linux";

  # Firmware boots UEFI (installer came up with /sys/firmware/efi).
  boot.loader.systemd-boot = { enable = true; configurationLimit = 5; };
  boot.loader.efi.canTouchEfiVariables = true;

  # services go here, e.g.:
  # virtualisation.podman.enable = true;
}
