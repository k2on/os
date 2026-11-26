# pkgs.pkgs-unstable: nixpkgs-unstable beside the release, as an overlay for
# a home (nixpkgs.overlays) and a NixOS module for a host
# (nixosModules.pkgsUnstable).
{ inputs, ... }:
let
  # pkgs.pkgs-unstable: nixpkgs-unstable beside the release, for the few
  # packages taken from it.
  unstable =
    final: prev:
    let
      inherit (prev) lib;
    in
    {
      pkgs-unstable = import inputs.nixpkgs-unstable {
        inherit (prev.stdenv.hostPlatform) system;

        config.allowUnfreePredicate =
          pkg:
          builtins.elem (lib.getName pkg) [
            "claude-code"
          ];
      };
    };
in
{
  # For a NixOS host and a home alike (a home sets nixpkgs.overlays itself).
  flake.overlays.unstable = unstable;

  flake.nixosModules.pkgsUnstable = {
    nixpkgs.overlays = [ unstable ];
  };
}
