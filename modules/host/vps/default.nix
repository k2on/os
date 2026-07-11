{ self, lib, den, ... }:
{
  den.hosts.x86_64-linux = {
    vps = {
      server-type = "cpx11";
      region = "ash";
    };
  };

  den.aspects.vps = { ...  }: {
    includes = [
      den.batteries.define-user
      den.batteries.hostname
    ];

    nixos = {
      imports = [
        ./_hardware-configuration.nix
        self.inputs.disko.nixosModules.default
        self.nixosModules.vps-filesystem
      ];

      boot.loader.grub.enable = true;
      services.openssh.enable = true;


      users.users.vps = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        initialHashedPassword = "$y$j9T$2DyEjQxPoIjTkt8zCoWl.0$3mHxH.fqkCgu53xa0vannyu4Cue3Q7xL4CrUhMxREKC"; # Password.123
      };

      programs.neovim = {
        enable = true;
        defaultEditor = true;
      };

      system.stateVersion = "25.05";
    };
  };
}
