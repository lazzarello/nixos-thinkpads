{
  description = "ThinkPad P1 (20MDCTO1WW) — NixOS with niri, DankMaterialShell and Voxtype";

  inputs = {
    # Pinned to the exact nixpkgs revision this machine was already running, so
    # converting to a flake is provably not also a system update. Verified by
    # comparing the built system's store path against the pre-conversion build.
    #
    # To update later, deliberately and on its own:
    #   nix flake update nixpkgs
    nixpkgs.url = "github:NixOS/nixpkgs/ecc58f32d1069a3e3f8a991e2233d365689f748d";

    voxtype = {
      url = "github:peteonrails/voxtype";
      # Build voxtype against our nixpkgs rather than its own, so we do not end
      # up with two nixpkgs revisions in the closure.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, voxtype, ... }:
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        # Make the flake inputs visible to modules, so desktop.nix and friends
        # can reach voxtype.packages without importing the flake again.
        specialArgs = { inherit voxtype; };

        modules = [
          ./configuration.nix
          voxtype.nixosModules.default
        ];
      };
    };
}
