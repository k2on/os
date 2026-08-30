{ ... }:
{
  flake.homeModules.koonMaxSsh =
    { ... }:
    {
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;

        # Attribute names are `Host` patterns; values use OpenSSH directive names.
        settings = {
          "*" = {
            AddKeysToAgent = "yes";
          };
          "m1" = {
            User = "admin";
          };
          "ark" = {
            User = "admin";
          };
          "github.com" = {
            User = "git";
            IdentityFile = "~/.ssh/id_maxkey";
          };
        };
      };

      home.file = {
        ".ssh/id_maxkey.pub".source = ./id_maxkey.pub;
      };
    };
}
