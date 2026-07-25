{ self, ... }:
{
  flake.nixosModules.kanidm = { pkgs, config, ... }:
    let
      domain = "koon.us";
    in {
    services.kanidm = {
      package = pkgs.kanidmWithSecretProvisioning_1_10;
      server = {
        enable = true;
        settings = {
          domain = "id.${domain}";
          origin = "https://id.koon.us";
          bindaddress = "0.0.0.0:8443";

          tls_chain = "/var/lib/acme/${domain}/fullchain.pem";
          tls_key = "/var/lib/acme/${domain}/key.pem";

        };
      };

      client = {
        enable = true;
        settings.uri = "https://id.${domain}";
      };

      provision = {
        enable = true;

        persons.max = { displayName = "Max Koon"; mailAddresses = [ "max@${domain}" ]; };
        persons.heather = { displayName = "Heather Koon"; mailAddresses = [ "heather@${domain}" ]; };

        groups.headscale_users.members = [ "max" "heather" ];

        groups.home_users.members = [ "max" ];
        groups.home_admins.members = [ "max" "heather" ];

        groups.photos_users.members = [ "max" "heather" ];

        groups.git_users.members = [ "max" ];

        systems.oauth2 = {
          headscale = {
            displayName = "VPN";
            originUrl = "https://headscale.redactedaddress.com/oidc/callback";
            originLanding = "https://headscale.redactedaddress.com";
            imageFile = "${self}/assets/vpn.svg";
            basicSecretFile = config.sops.secrets.headscale_oidc_client_secret.path;
            preferShortUsername = true;
            scopeMaps.headscale_users = [ "openid" "profile" "email" "groups" ];
          };
          home = {
            displayName = "Home";
            originUrl = "https://home.koon.us/auth/oidc/callback";
            originLanding = "https://home.koon.us";
            imageFile = "${self}/assets/home.svg";
            basicSecretFile = config.sops.secrets.home_oidc_client_secret.path;
            preferShortUsername = true;
            scopeMaps.home_users = [ "openid" "profile" "email" "groups" ];
          };
          photos = {
            displayName = "Photos";
            originUrl = "https://photos.koon.us/auth/login";
            originLanding = "https://photos.koon.us";
            imageFile = "${self}/assets/photos.svg";
            basicSecretFile = config.sops.secrets.photos_oidc_client_secret.path;
            preferShortUsername = true;
            scopeMaps.photos_users = [ "openid" "profile" "email" "groups" ];
          };
          git = {
            displayName = "Git";
            originUrl = "https://git.koon.us/user/oauth2/KoonFamily/callback";
            originLanding = "https://git.koon.us";
            imageFile = "${self}/assets/git.svg";
            basicSecretFile = config.sops.secrets.git_oidc_client_secret_kanidm.path;
            preferShortUsername = true;
            scopeMaps.git_users = [ "openid" "profile" "email" "groups" ];
            # XXX: PKCE is currently not supported by gitea/forgejo,
            # see https://github.com/go-gitea/gitea/issues/21376.
            allowInsecureClientDisablePkce = true;
          };
        };

      };
    };

    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8443 ];

    systemd.services.kanidm = {
      wants = [ "acme-finished-koon.us.target" ];
      after = [ "acme-finished-koon.us.target" ];
    };

    systemd.services.kanidm.serviceConfig.ExecReload = "/run/current-system/sw/bin/kill -HUP $MAINPID";
  };
}
