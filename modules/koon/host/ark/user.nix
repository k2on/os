{ ... }: {
  flake.nixosModules.koonArkUser = { pkgs, config, ... }: {
    sops.secrets.admin-password.neededForUsers = true;
    users.mutableUsers = false;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      hashedPasswordFile = config.sops.secrets.admin-password.path;
      packages = with pkgs; [ tree vim tmux restic ];
    };
  };
}
