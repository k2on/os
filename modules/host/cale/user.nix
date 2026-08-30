{ ... }:
{
  flake.nixosModules.koonMaxUser =
    { pkgs, config, ... }:
    {

      sops.secrets.max-password.neededForUsers = true;

      users.mutableUsers = false;

      users.users.max = {
        isNormalUser = true;
        hashedPasswordFile = config.sops.secrets.max-password.path;

        extraGroups = [
          "wheel"
          "networkmanager"
          "video"
          "kvm"
          "docker"
          "ydotool"
        ];
        packages = with pkgs; [
          tree
          # # systemd 258 handles adb uaccess rules automatically; the
          # # `programs.adb` module was removed, so just ship the CLI.
          # android-tools
        ];
        shell = pkgs.zsh;
      };

      virtualisation.docker = {
        enable = true;

        rootless = {
          enable = true;
          setSocketVariable = true;
        };
      };
    };
}
