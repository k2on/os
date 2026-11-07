{ root, ... }:
{
  flake.nixosModules.koonMaxSops =
    { config, ... }:
    {
      sops = {
        age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

        # The file alone, not the repo (see lib/secrets.nix).
        defaultSopsFile = builtins.path {
          path = root + "/secrets/koon/max/default.yaml";
          name = "cale-default.yaml";
        };

        validateSopsFiles = false;

        secrets = {
          "waka_config" = {
            owner = config.users.users.max.name;
            inherit (config.users.users.max) group;
            path = "/home/max/.wakatime.cfg";
          };

          "proton_key" = { };
        };

      };
      environment.sessionVariables.PROTON_PASS_ENCRYPTION_KEY = config.sops.secrets.proton_key.path;
    };
}
