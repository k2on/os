{
  description = "Koon OS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.05";

    unstable.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    nixos-apple-silicon.url =
      "github:nix-community/nixos-apple-silicon?ref=release-2025-05-30";

    home-manager = {
      url = "github:nix-community/home-manager?ref=release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    nixvim = {
      url = "github:nix-community/nixvim?ref=nixos-25.05";
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
  };

  outputs = { self, nixpkgs, unstable, nixos-apple-silicon, home-manager
    , plasma-manager, nixvim, sops-nix, terranix, ... }: {

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
          secrets = import ./secrets;
        in nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit pkgs-unstable secrets; };
          modules = [
            ./host/max/default.nix
            nixos-apple-silicon.nixosModules.apple-silicon-support
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit secrets; };
              home-manager.users.max = { config, pkgs, lib, ... }: {
                imports = [
                  sops-nix.homeManagerModules.sops
                  nixvim.homeManagerModules.nixvim
                  plasma-manager.homeManagerModules.plasma-manager
                  ./host/max/home.nix # Import your home.nix here
                ];
              };
            }
          ];
        };

        ark = let system = "x86_64-linux";
        in unstable.lib.nixosSystem {
          inherit system;
          modules = [
            ./host/ark/default.nix 
            sops-nix.nixosModules.sops
          ];
        };
      };
    };
}
