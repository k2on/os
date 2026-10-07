{
  description = "Koon OS";

  inputs = {
    den.url = "github:denful/den";
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-26.05";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    nixos-apple-silicon.url = "github:nix-community/nixos-apple-silicon?ref=release-2026-07-30";

    home-manager = {
      url = "github:nix-community/home-manager?ref=release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvim = {
      url = "github:nix-community/nixvim?ref=nixos-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      # IMPORTANT: we're using "libgbm" and is only available in unstable so ensure
      # to have it up-to-date or simply don't specify the nixpkgs input
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    harken.url = "github:k2on/harken";
  };

  # secrets/ is the private submodule: besides sops files it carries the
  # people side of the config (secrets/ark.nix), so it is a module root too.
  # It is only there with `?submodules=1`; without it Nix sees an untracked
  # path, so only reference it once we know it was checked out.
  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      inputs.import-tree (
        [ ./modules ] ++ (if builtins.pathExists ./secrets/ark.nix then [ ./secrets ] else [ ])
      )
    );
}
