{ config, ... }:
{
  sops = {

    defaultSopsFile = ../../secrets/sops/host/ark/default.yaml;
    validateSopsFiles = false;

    age.keyFile = if builtins.pathExists /var/lib/sops-nix/key.txt then
      "/var/lib/sops-nix/key.txt"
    else
      "/home/admin/.config/sops/age/keys.txt" # temp decrypt key
    ;

    secrets = {
      "host_age_key" = {
        path = "/var/lib/sops-nix/key.txt";
      };

      "restic-password" = {};
      "tunnel-credentials" = {};
      "admin-password" = {};

      "waka-password-salt" = {
        owner = config.users.users.wakapi.name;
      };

      "money-env" = {
        owner = config.users.users.money.name;
      };

      "photos/clientId" = {
        sopsFile = ../../secrets/sops/host/ark/oauth.yaml;
      };
      "photos/clientSecret" = {
        sopsFile = ../../secrets/sops/host/ark/oauth.yaml;
      };

      "git/clientId" = {
        sopsFile = ../../secrets/sops/host/ark/oauth.yaml;
        owner = config.services.gitea.user;
      };
      "git/clientSecret" = {
        sopsFile = ../../secrets/sops/host/ark/oauth.yaml;
        owner = config.services.gitea.user;
      };

      "docs/clientId" = {
        sopsFile = ../../secrets/sops/host/ark/oauth.yaml;
        owner = config.services.outline.user;
      };
      "docs/clientSecret" = {
        sopsFile = ../../secrets/sops/host/ark/oauth.yaml;
        owner = config.services.outline.user;
      };
      "money/clientId" = {
        sopsFile = ../../secrets/sops/host/ark/oauth.yaml;
        owner = config.users.users.money.name;
      };
      "money/clientSecret" = {
        sopsFile = ../../secrets/sops/host/ark/oauth.yaml;
        owner = config.users.users.money.name;
      };
    };
  };
}
