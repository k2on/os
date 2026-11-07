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
          "ephr" = {
            User = "admin";
          };
          "ark" = {
            User = "admin";
          };
          "adam" = {
            User = "admin";
          };
          "github.com" = {
            User = "git";
            IdentityFile = "~/.ssh/id_ed25519_sk";
          };
        };
      };
    };
}
