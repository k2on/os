{ self, ... }: {
  flake.nixosModules.koonArkSops = { config, ... }: {
    sops = {
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      defaultSopsFile = "${self}/secrets/koon/ark/default.yaml";

      validateSopsFiles = false;

      secrets = {
        "restic-password" = {};
        "tunnel-credentials" = {};
        "admin-password" = {};

        "cloudflare-api-key" = {};

        "pocket-id-encryption-key" = {
          owner = config.services.pocket-id.user;
        };

        "waka-password-salt" = {
          owner = config.users.users.wakapi.name;
        };

        "oauth/git/clientId" = {
          owner = config.services.gitea.user;
        };
        "oauth/git/clientSecret" = {
          owner = config.services.gitea.user;
        };

        "headscale_oidc_client_secret" = {
          owner = "kanidm";
          sopsFile = "${self}/secrets/sops/oidc/headscale.yaml";
        };
      };
    };
  };
}
