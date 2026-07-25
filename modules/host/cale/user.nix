{ ... }: {
  flake.nixosModules.koonMaxUser = { pkgs, config, ... }: {

    sops.secrets.max-password.neededForUsers = true;

    users.mutableUsers = false;

    users.users.max = {
      isNormalUser = true;
      hashedPasswordFile = config.sops.secrets.max-password.path;

      extraGroups = [ "wheel" "networkmanager" "video" "kvm" "docker" "ydotool" ];
      packages = with pkgs; [ tree ];
      shell = pkgs.zsh;
    };

    programs.adb.enable = true;

    virtualisation.docker = {
      enable = true;

      rootless = {
        enable = true;
        setSocketVariable = true;
      };
    };
  };
}

