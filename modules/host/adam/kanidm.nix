{ self, config, ... }:
let
  ark = config.ark;
in
{
  flake.nixosModules.kanidm =
    { pkgs, config, ... }:
    {
      services.kanidm = {
        package = pkgs.kanidmWithSecretProvisioning_1_10;
        server = {
          enable = true;
          settings = {
            domain = "id.${ark.mainDomain}";
            origin = "https://id.${ark.mainDomain}";
            bindaddress = "0.0.0.0:8443";

            tls_chain = "/var/lib/acme/${ark.mainDomain}/fullchain.pem";
            tls_key = "/var/lib/acme/${ark.mainDomain}/key.pem";

          };
        };

        client = {
          enable = true;
          settings.uri = "https://id.${ark.mainDomain}";
        };

        provision = {
          enable = true;

          persons.max = {
            displayName = "Max Koon";
            mailAddresses = [ "max@${ark.mainDomain}" ];
          };
          persons.heather = {
            displayName = "Heather Koon";
            mailAddresses = [ "heather@${ark.mainDomain}" ];
          };

          groups.headscale_users.members = [
            "max"
            "heather"
          ];

          groups.home_users.members = [ "max" ];
          groups.home_admins.members = [
            "max"
            "heather"
          ];

          groups.photos_users.members = [
            "max"
            "heather"
          ];

          groups.git_users.members = [ "max" ];

          groups.cloud_users.members = [
            "max"
            "heather"
          ];

          systems.oauth2 = {
            headscale = {
              displayName = "VPN";
              originUrl = "https://vpn.${ark.mainDomain}/oidc/callback";
              originLanding = "https://vpn.${ark.mainDomain}";
              imageFile = "${self}/assets/vpn.svg";
              basicSecretFile = config.sops.secrets.headscale_oidc_client_secret.path;
              preferShortUsername = true;
              scopeMaps.headscale_users = [
                "openid"
                "profile"
                "email"
                "groups"
              ];
            };
            home = {
              displayName = "Home";
              originUrl = "https://home.${ark.mainDomain}/auth/oidc/callback";
              originLanding = "https://home.${ark.mainDomain}";
              imageFile = "${self}/assets/home.svg";
              basicSecretFile = config.sops.secrets.home_oidc_client_secret.path;
              preferShortUsername = true;
              scopeMaps.home_users = [
                "openid"
                "profile"
                "email"
                "groups"
              ];
            };
            photos = {
              displayName = "Photos";
              originUrl = [
                "https://photos.${ark.mainDomain}/auth/login"
                "app.immich:///oauth-callback"
              ];
              originLanding = "https://photos.${ark.mainDomain}";
              imageFile = "${self}/assets/photos.svg";
              basicSecretFile = config.sops.secrets.photos_oidc_client_secret.path;
              preferShortUsername = true;
              scopeMaps.photos_users = [
                "openid"
                "profile"
                "email"
                "groups"
              ];
            };
            git = {
              displayName = "Git";
              originUrl = "https://git.${ark.mainDomain}/user/oauth2/KoonFamily/callback";
              originLanding = "https://git.${ark.mainDomain}";
              imageFile = "${self}/assets/git.svg";
              basicSecretFile = config.sops.secrets.git_oidc_client_secret_kanidm.path;
              preferShortUsername = true;
              scopeMaps.git_users = [
                "openid"
                "profile"
                "email"
                "groups"
              ];
              # XXX: PKCE is currently not supported by gitea/forgejo,
              # see https://github.com/go-gitea/gitea/issues/21376.
              allowInsecureClientDisablePkce = true;
            };
            cloud = {
              displayName = "Cloud";
              originUrl = "https://cloud.${ark.mainDomain}/apps/user_oidc/code";
              originLanding = "https://cloud.${ark.mainDomain}";
              imageFile = "${self}/assets/photos.svg";
              basicSecretFile = config.sops.secrets.cloud_oidc_client_secret_kanidm.path;
              preferShortUsername = true;
              scopeMaps.cloud_users = [
                "openid"
                "profile"
                "email"
                "groups"
              ];
            };
          };

        };
      };

      networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8443 ];

      systemd.services.kanidm = {
        wants = [ "acme-finished-${ark.mainDomain}.target" ];
        after = [ "acme-finished-${ark.mainDomain}.target" ];
      };

      systemd.services.kanidm.serviceConfig.ExecReload = "/run/current-system/sw/bin/kill -HUP $MAINPID";
    };
}
