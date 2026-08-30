{ inputs, ... }:
{
  flake.nixosModules.commonUnstablePkgsOverlay =
    { lib, ... }:
    {
      nixpkgs.overlays = [
        (final: prev: {
          pkgs-unstable = import inputs.nixpkgs-unstable {
            inherit (prev.stdenv.hostPlatform) system;

            config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
              "claude-code"
            ];
          };
        })
      ];
    };
}
