{ ... }: {
  # Raspberry Pi 3 — DNS, rclone/calendar sync, small jobs
  imports = [ ./hardware-configuration.nix ];
  nixpkgs.hostPlatform = "aarch64-linux";

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Never build here: pull everything from a binary cache (no builder host yet).
  # nix.settings.max-jobs = 0;   # enable once a cache/builder host exists

  # services.adguardhome.enable = true;
}
