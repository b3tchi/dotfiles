{ ... }: {
  # Acer Revo RL70 — AMD E-450, light services
  imports = [ ./hardware-configuration.nix ];   # copy from the box after install
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.loader.grub = { enable = true; device = "/dev/sda"; };  # legacy BIOS

  # services go here, e.g.:
  # virtualisation.podman.enable = true;
}
