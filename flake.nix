{
  description = "Koon OS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";

    nixpkgs-old.url = "github:nixos/nixpkgs?ref=nixos-25.05";

    unstable.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    nixos-apple-silicon.url =
      "github:nix-community/nixos-apple-silicon?ref=release-2025-11-18";

    home-manager = {
      url = "github:nix-community/home-manager?ref=release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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

    elytrarides = {
      url = "github:k2on/elytrarides";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      # IMPORTANT: we're using "libgbm" and is only available in unstable so ensure
      # to have it up-to-date or simply don't specify the nixpkgs input
      inputs.nixpkgs.follows = "unstable";
    };

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    apple-fonts.url= "github:Lyndeno/apple-fonts.nix";

    proton-pass-cli.url = "github:yuxqiu/proton-pass-cli-nix";

    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = { self, nixpkgs, unstable, nixos-apple-silicon, home-manager
    , plasma-manager, nixvim, sops-nix, terranix, elytrarides, zen-browser, apple-fonts, nixpkgs-old, proton-pass-cli, firefox-addons, ... }:
    let
      forAllSystems = function:
        nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed
        (system: function nixpkgs.legacyPackages.${system});
    in {

      packages.aarch64-linux = 
      let
        system = "aarch64-linux";

        pkgs = import unstable {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };

        terraform = pkgs.terraform.withPlugins (p: [
          p.pocketid
          p.local
        ]);
        terraformConfiguration = terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ ./infra/config.nix ];
        };
      in {
        deploy = pkgs.writeShellScriptBin "deploy" ''
          echo Deploying Infrastructure...

          export TF_VAR_pocketid_api_token=$(${pkgs.sops}/bin/sops -d --extract '["pocketid-api-token"]' secrets/secrets.yaml)

          cd infra

          cp ${terraformConfiguration} config.tf.json

          ${terraform}/bin/terraform init
          ${terraform}/bin/terraform apply

          rm -f config.tf.json

          echo Done

          echo Encrypting secrets

          cd ../secrets

          ${pkgs.sops}/bin/sops -e -i sops/oauth.yaml

          echo Done
        '';
      };

      nixosConfigurations = {
        max = let
          system = "aarch64-linux";
          pkgs-unstable = import unstable { inherit system; };
          pkgs-old = import nixpkgs-old { inherit system; };
          secrets = import ./secrets;
        in nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit pkgs-unstable secrets zen-browser apple-fonts pkgs-old proton-pass-cli; };
          modules = [
            ./host/max/default.nix
            nixos-apple-silicon.nixosModules.apple-silicon-support
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit secrets zen-browser firefox-addons; };
              home-manager.users.max = { config, pkgs, lib, ... }: {
                imports = [
                  sops-nix.homeManagerModules.sops
                  nixvim.homeModules.nixvim
                  plasma-manager.homeManagerModules.plasma-manager
                  zen-browser.homeModules.beta
                  ./host/max/home.nix # Import your home.nix here
                ];
              };
            }
          ];
        };

        ark = let
          system = "x86_64-linux";
          secrets = import ./secrets;
        in unstable.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit elytrarides secrets; };
          modules = [
            ./host/ark/default.nix 
            sops-nix.nixosModules.sops
          ];
        };
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            age
            ssh-to-age
            sops
            just
          ];
        };
      });
    };
}
