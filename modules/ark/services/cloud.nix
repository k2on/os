{ self, config, ... }:
let
  ark = config.ark;
in
  {
  ark.services.cloud = { service, pkgs, config, ... }: {
    environment.etc."nextcloud-admin-pass".text = "password123456789";

    sops.secrets.cloud_oidc_client_secret_kanidm = {
      sopsFile = "${self}/secrets/sops/oidc/cloud.yaml";
      key = "cloud_oidc_client_secret";
      owner = "kanidm";
    };
    sops.secrets.cloud_oidc_client_secret = {
      sopsFile = "${self}/secrets/sops/oidc/cloud.yaml";
      owner = "nextcloud";
    };

    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud33;
      hostName = "nextcloud.internal";
      https = true;
      config.adminpassFile = "/etc/nextcloud-admin-pass";
      config.dbtype = "sqlite";
      extraApps = {
        inherit (config.services.nextcloud.package.packages.apps) mail contacts calendar richdocuments tasks user_oidc;
      };
      extraAppsEnable = true;
      settings = {
        overwritehost = "cloud.${ark.mainDomain}";
        overwriteprotocol = "https";
        overwrite.cli.url = "https://cloud.${ark.mainDomain}";
        trusted_domains = [ "cloud.${ark.mainDomain}" ];
        trusted_proxies = [ "127.0.0.1" ];
        allow_local_remote_servers = true;
      };
    };


    services.nginx.virtualHosts = {
      "office.${ark.mainDomain}" = {
        useACMEHost = ark.mainDomain;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://localhost:${toString (service.port + 1)}";
          proxyWebsockets = true;
        };
      };
    };

    networking.hosts."127.0.0.1" = [
      # "id.${ark.mainDomain}"
      "office.${ark.mainDomain}"
      "cloud.${ark.mainDomain}"
    ];

    services.collabora-online = {
      enable = true;
      port = service.port + 1;
      settings = {
        server_name = "office.${ark.mainDomain}";
        ssl = {
          enable = false;       # nginx terminates TLS
          termination = true;
        };
        net = {
          listen = "loopback";
          post_allow.host = [ "127\\.0\\.0\\.1" ];
        };
        storage.wopi = {
          "@allow" = true;
          host = [ "cloud\\.${ark.mainDomain}" ];  # regex: escape the dots
        };
        aliasgroups = [
          { host = "https://cloud.${ark.mainDomain}:443"; }
        ];
      };
    };


    systemd.services.nextcloud-oidc-provision = {
      after = [ "nextcloud-setup.service" ];
      requires = [ "nextcloud-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "nextcloud";
      };
      script = ''
        ${config.services.nextcloud.occ}/bin/nextcloud-occ user_oidc:provider KoonFamily \
          --clientid="cloud" \
          --clientsecret="$(cat ${config.sops.secrets."cloud_oidc_client_secret".path})" \
          --discoveryuri="https://id.${ark.mainDomain}/oauth2/openid/cloud/.well-known/openid-configuration" \
          --scope="openid email profile" \
          --unique-uid=0 \
          --mapping-uid=preferred_username \
          --mapping-display-name=name \
          --mapping-email=email


        ${config.services.nextcloud.occ}/bin/nextcloud-occ config:app:set richdocuments \
          wopi_url --value="https://office.${ark.mainDomain}"
        ${config.services.nextcloud.occ}/bin/nextcloud-occ config:app:set richdocuments \
          wopi_allowlist --value="127.0.0.1,::1"
        ${config.services.nextcloud.occ}/bin/nextcloud-occ richdocuments:activate-config
      '';
    };
    services.nginx.virtualHosts."nextcloud.internal".listen = [
      { addr = "127.0.0.1"; port = service.port; }
    ];
  };
}

