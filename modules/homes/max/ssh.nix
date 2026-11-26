{ ... }:
{
  den.aspects.max.homeManager =
    { ... }:
    {
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;

        # Attribute names are `Host` patterns; values use OpenSSH directive names.
        settings = {
          "*" = {
            AddKeysToAgent = "yes";
            # One connection per server, kept 10 minutes after its last use,
            # so the security key is touched once rather than per command.
            # The same socket as `ark` (modules/ark/cli/src/util.rs).
            ControlMaster = "auto";
            ControlPath = "\${XDG_RUNTIME_DIR}/ssh-%C";
            ControlPersist = "10m";
          };
          "github.com" = {
            User = "git";
            IdentityFile = "~/.ssh/id_ed25519_sk";
          };
        };
      };
    };
}
