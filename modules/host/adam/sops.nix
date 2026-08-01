{ self, ... }: {
  flake.nixosModules.koonArkSops = { config, ... }: {
    sops = {
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      defaultSopsFile = "${self}/secrets/koon/ark/default.yaml";

      validateSopsFiles = false;

      secrets = {
        "restic-password" = {};
        "admin-password" = {};

        "cloudflare-api-key" = {};

        "waka-password-salt" = {
          owner = config.users.users.wakapi.name;
        };

        "headscale_oidc_client_secret" = {
          owner = "kanidm";
          sopsFile = "${self}/secrets/sops/oidc/headscale.yaml";
        };
      };
    };
  };
}
