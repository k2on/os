{ ... }:
{
  flake.nixosModules.koonMaxUser =
    { pkgs, config, ... }:
    {

      sops.secrets.max-password.neededForUsers = true;

      users.users.max = {
        isNormalUser = true;
        hashedPasswordFile = config.sops.secrets.max-password.path;

        extraGroups = [
          "wheel"
          "networkmanager"
          "video"
          "kvm"
          "adbusers"
        ];
        shell = pkgs.zsh;
      };
    };
}
