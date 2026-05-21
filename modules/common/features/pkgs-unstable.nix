{ inputs, ... }: {
  flake.nixosModules.commonUnstablePkgsOverlay = { ... }: {
    nixpkgs.overlays = [
      (final: prev: {
        pkgs-unstable = import inputs.nixpkgs-unstable {
          inherit (prev.stdenv.hostPlatform) system;
        };
      })
    ];
  };
} 
