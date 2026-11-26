{ ... }:
{
  flake.nixosModules.koonMaxUser =
    { pkgs, config, ... }:
    {
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
