{ root, ... }:
{
  flake.nixosModules.koonArkSops =
    { config, ... }:
    {
      ark.hostKey = "age145k3ef7n7sf7q4svqwv2las7ze9jaasc5ku36ln53mpxxp422quqg8ryc6";

      sops = {
        age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

        # The file alone, not the repo (see lib/secrets.nix).
        defaultSopsFile = builtins.path {
          path = root + "/secrets/koon/ark/default.yaml";
          name = "adam-default.yaml";
        };

        validateSopsFiles = false;

        secrets = {
          "restic-password" = { };
          "admin-password" = { };

          "cloudflare-api-key" = { };

          "waka-password-salt" = {
            owner = config.users.users.wakapi.name;
          };
        };
      };
    };
}
