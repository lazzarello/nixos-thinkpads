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

    # Unstable, used only for packages that have to track upstream closely.
    # Currently that is just claude-code, which ships several releases a week
    # while the pinned nixpkgs above deliberately stays put (it has 2.1.223;
    # unstable is normally within a patch of the npm release).
    #
    # Kept as its own input so bumping it is also a single, deliberate act:
    #   nix flake update nixpkgs-unstable
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    voxtype = {
      url = "github:peteonrails/voxtype";
      # Build voxtype against our nixpkgs rather than its own, so we do not end
      # up with two nixpkgs revisions in the closure.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      voxtype,
      ...
    }:
    let
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        inherit system;

        # Make the flake inputs visible to modules, so desktop.nix and friends
        # can reach voxtype.packages without importing the flake again.
        specialArgs = {
          inherit voxtype;

          # A second package set for the handful of packages taken from
          # unstable. This is a separate instantiation, so the
          # nixpkgs.config set in configuration.nix does not reach it --
          # allowUnfree has to be repeated here (claude-code is unfree).
          pkgs-unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };
        };

        modules = [
          ./configuration.nix
          voxtype.nixosModules.default
        ];
      };
    };
}
