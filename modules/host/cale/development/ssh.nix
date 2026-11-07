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
          "github.com" = {
            User = "git";
            IdentityFile = "~/.ssh/id_ed25519_sk";
          };
        };
      };
    };
}
