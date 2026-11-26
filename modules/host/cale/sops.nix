{ root, ... }:
{
  flake.nixosModules.koonMaxSops =
    { config, ... }:
    {
      sops = {
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
        };
      };
    };
}
