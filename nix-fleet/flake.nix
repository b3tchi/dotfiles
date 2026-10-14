{
  description = "Home fleet: each host pulls its own config from NFS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05"; # bump to current stable

  outputs = { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      # Every folder in ./hosts becomes a config (on the NAS each export holds only one).
      hostNames = builtins.attrNames
        (lib.filterAttrs (_: t: t == "directory") (builtins.readDir ./hosts));

      mkHost = name: lib.nixosSystem {
        specialArgs = { hostName = name; };
        modules = [ ./modules/common.nix ./hosts/${name} ];
      };

      all = lib.genAttrs hostNames mkHost;

      # publish.sh writes HOST into each export, so every host runs "#default".
      default = lib.optionalAttrs (builtins.pathExists ./HOST) {
        default = mkHost (lib.removeSuffix "\n" (builtins.readFile ./HOST));
      };
    in {
      nixosConfigurations = all // default;
    };
}
