{
  self,
  lib,
  den,
  ...
}:
let
  # This folder's name: the host's, its flake output's and its hostname.
  name = baseNameOf ./.;
in
{
  den.hosts.x86_64-linux = {
    ${name} = {
      provider = "hetzner";
      color = "#fab387"; # orange
      dnsResolver = true;
      server-type = "cpx11";
      region = "ash";
    };
  };

  # comin deploys benj (aspects/deploy.nix). A fresh server is installed by
  # hand: nixos-anywhere --flake .#benj root@<address>.
  den.aspects.${name} =
    { ... }:
    {
      includes = [
        den.batteries.define-user
        den.aspects.headscale
        den.aspects.mail
        den.aspects.security
        den.aspects.deploy
        den.aspects.login
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
        # Who may sign in, and how: aspects/login.nix.
        services.openssh.enable = true;

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
