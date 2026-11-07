{
  self,
  lib,
  config,
  den,
  ...
}:
{
  den.hosts.x86_64-linux = {
    benj = {
      provider = "hetzner";
      server-type = "cpx11";
      region = "ash";
    };
  };

  # Until benj's comin, configured as vps, has deployed this commit: it
  # looks for nixosConfigurations.vps, gets benj and follows the new name.
  flake.nixosConfigurations.vps = config.flake.nixosConfigurations.benj;

  # comin deploys benj (aspects/deploy.nix). A fresh server is installed by
  # hand: nixos-anywhere --flake .#benj root@<address>.
  den.aspects.benj =
    { ... }:
    {
      includes = [
        den.batteries.define-user
        den.aspects.headscale
        den.aspects.mail
        den.aspects.security
        den.aspects.deploy
      ];

      nixos = {
        imports = [
          ./_hardware-configuration.nix
          self.inputs.disko.nixosModules.default
          self.inputs.sops-nix.nixosModules.sops
          self.nixosModules.vps-filesystem
          self.nixosModules.vps-sops
        ];

        boot.loader.grub.enable = true;
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = false;
            PermitRootLogin = "prohibit-password";
          };
        };

        users.users.vps = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          initialHashedPassword = "$y$j9T$2DyEjQxPoIjTkt8zCoWl.0$3mHxH.fqkCgu53xa0vannyu4Cue3Q7xL4CrUhMxREKC"; # Password.123

          openssh.authorizedKeys.keys = [
            (builtins.readFile ../../aspects/key.pub)
          ];
        };

        users.users.root = {
          openssh.authorizedKeys.keys = [
            (builtins.readFile ../../aspects/key.pub)
          ];
        };

        # 2 GB and it builds its own system: compressed swap in memory, so a
        # big compile slows down rather than crashes.
        zramSwap.enable = true;

        programs.neovim = {
          enable = true;
          defaultEditor = true;
        };

        system.stateVersion = "25.05";
      };
    };
}
