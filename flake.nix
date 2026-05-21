{
  description = "Koon OS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";

    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    wrapper-modules.url = "github:BirdeeHub/nix-wrapper-modules";

    nixos-apple-silicon.url =
      "github:nix-community/nixos-apple-silicon?ref=release-2025-11-18";

    home-manager = {
      url = "github:nix-community/home-manager?ref=release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hm-wrapper-modules.url = "github:sini/hm-wrapper-modules";
    hm-wrapper-modules.inputs.nixpkgs.follows = "nixpkgs";
    hm-wrapper-modules.inputs.home-manager.follows = "home-manager";

    nixvim = {
      url = "github:nix-community/nixvim?ref=nixos-25.11";
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

    apple-fonts.url= "github:Lyndeno/apple-fonts.nix";
  };


  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs;} (inputs.import-tree ./modules);

  # outputs = { self, nixpkgs, nixpkgs-unstable, nixos-unstable, nixos-apple-silicon, home-manager
  #   , nixvim, sops-nix, terranix, zen-browser, apple-fonts, proton-pass-cli, firefox-addons, ... }:
  #   let
  #     forAllSystems = function:
  #       nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed
  #       (system: function nixpkgs.legacyPackages.${system});
  #   in {
  #
  #     nixosConfigurations = {
  #       max = let
  #         system = "aarch64-linux";
  #         pkgs-unstable = import nixpkgs-unstable { inherit system; };
  #         secrets = import ./secrets;
  #       in nixpkgs.lib.nixosSystem {
  #         inherit system;
  #         specialArgs = { inherit pkgs-unstable secrets zen-browser apple-fonts proton-pass-cli; };
  #         modules = [
  #           ./host/max/default.nix
  #           nixos-apple-silicon.nixosModules.apple-silicon-support
  #           sops-nix.nixosModules.sops
  #           home-manager.nixosModules.home-manager
  #           {
  #             home-manager.useGlobalPkgs = true;
  #             home-manager.useUserPackages = true;
  #             home-manager.extraSpecialArgs = { inherit secrets zen-browser firefox-addons system pkgs-unstable; };
  #             home-manager.users.max = { config, pkgs, lib, ... }: {
  #               imports = [
  #                 sops-nix.homeManagerModules.sops
  #                 nixvim.homeModules.nixvim
  #                 zen-browser.homeModules.beta
  #                 ./host/max/home.nix # Import your home.nix here
  #               ];
  #             };
  #           }
  #         ];
  #       };
  #
  #       ark = let
  #         system = "x86_64-linux";
  #         secrets = import ./secrets;
  #       in nixos-unstable.lib.nixosSystem {
  #         inherit system;
  #         specialArgs = { inherit secrets; };
  #         modules = [
  #           ./host/ark/default.nix 
  #           sops-nix.nixosModules.sops
  #         ];
  #       };
  #     };
  #
  #     devShells = forAllSystems (pkgs: {
  #       default = pkgs.mkShell {
  #         packages = with pkgs; [
  #           age
  #           ssh-to-age
  #           sops
  #           just
  #         ];
  #       };
  #     });
  #   };
}
