{ self, config, ... }:
let
  ark = config.ark;
  shareDomain = "share.${ark.mainDomain}";
in
{
  # Shared albums are public through immich-public-proxy on share.*: it
  # answers only for links Immich has shared, from Immich's own API, so
  # Immich itself stays on the tailnet. The vps passes share.* through to
  # ark's nginx (lib/public.nix).
  ark.public.share = 443;

  ark.services.photos = {
    oidc.callbacks = [
      "/auth/login"
      "app.immich:///oauth-callback"
    ];

    nixos =
      {
        config,
        lib,
        pkgs,
        service,
        ...
      }:
      {
        sops = {
          templates = {
            "immich-config.json" = {
              content = builtins.toJSON {
                passwordLogin.enabled = false;

                # We will do this ourselves
                backup.database.enabled = false;

                # Links Immich hands out point at the public proxy.
                server.externalDomain = "https://${shareDomain}";

                oauth = {
                  enabled = true;
                  autoLaunch = true;
                  autoRegister = true;
                  buttonText = "Login To ${service.oidc.name}";
                  inherit (service.oidc) clientId clientSecret;
                  issuerUrl = service.oidc.discovery;
                  signingAlgorithm = "ES256";
                };
              };
              owner = config.users.users.immich.name;
              mode = "0400";
              restartUnits = [
                "immich-server.service"
              ];
            };
          };
        };

        services.immich = {
          enable = true;
          host = "127.0.0.1";
          port = service.port;
          environment.IMMICH_CONFIG_FILE = config.sops.templates."immich-config.json".path;
          accelerationDevices = null;

          machine-learning.environment = {
            HF_XET_CACHE = "/var/cache/immich/huggingface-xet";
          };

        };

        # Serves /share/<key> and /s/<slug> exactly as Immich links them, from
        # Immich's API on loopback. /photos/<name> is the slug link under the
        # name people are given (keys are long random strings nobody types);
        # the proxy's own asset and media paths are absolute (/share/static,
        # /share/photo), so the whole host is its.
        services.immich-public-proxy = {
          enable = true;
          immichUrl = "http://127.0.0.1:${toString service.port}";
          port = service.port + 1;
        };
        systemd.services.immich-public-proxy = {
          # og: tags on a share page need the public origin, not the tailnet one.
          environment.PUBLIC_BASE_URL = "https://${shareDomain}";
          # Its startup version check hits Immich; do not race it.
          after = [ "immich-server.service" ];
          wants = [ "immich-server.service" ];
        };

        services.nginx.virtualHosts.${shareDomain} = {
          useACMEHost = ark.mainDomain;
          forceSSL = true;
          locations = {
            "/".proxyPass = "http://127.0.0.1:${toString config.services.immich-public-proxy.port}";
            "= /photos".proxyPass =
              "http://127.0.0.1:${toString config.services.immich-public-proxy.port}/share/";
            "/photos/".proxyPass = "http://127.0.0.1:${toString config.services.immich-public-proxy.port}/s/";
          };
        };

        users.users.immich = {
          home = "/var/lib/immich";
          createHome = true;
          extraGroups = [
            "video"
            "render"
          ];
        };

        hardware.graphics = {
          enable = true;
          extraPackages = with pkgs; [ intel-media-driver ];
        };
        environment.sessionVariables = {
          LIBVA_DRIVER_NAME = "iHD";
        };

        services.restic.backups = {
          immich-local = {
            repository = "/mnt/hdd/restic/immich";
            passwordFile = config.sops.secrets.restic-password.path;
            initialize = true;
            paths = [
              "/var/lib/immich/upload"
              "/var/backup/immich"
            ];
            backupPrepareCommand = ''
              mkdir -p /var/backup/immich

              ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl stop immich-server
              ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl stop immich-machine-learning

              ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql}/bin/pg_dump \
                --clean \
                --if-exists \
                --dbname=immich > /var/backup/immich/postgres.sql
            '';
            backupCleanupCommand = ''
              ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl start immich-server
              ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl start immich-machine-learning
            '';
          };
          immich-remote = {
            repository = "rest:http://m1:8000/immich";
            passwordFile = config.sops.secrets.restic-password.path;
            initialize = true;
            paths = [
              "/var/lib/immich/upload"
              "/var/backup/immich"
            ];
            backupPrepareCommand = ''
              mkdir -p /var/backup/immich

              ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl stop immich-server
              ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl stop immich-machine-learning

              ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql}/bin/pg_dump \
                --clean \
                --if-exists \
                --dbname=immich > /var/backup/immich/postgres.sql
            '';
            backupCleanupCommand = ''
              ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl start immich-server
              ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl start immich-machine-learning
            '';
          };
        };

        environment.systemPackages =
          with pkgs;
          let
            scripts = with pkgs; {
              restore_immich_pg = writeShellScriptBin "restore_immich_pg" ''
                ${pkgs.sudo}/bin/sudo -u postgres psql --dbname=immich < /var/backup/immich/postgres.sql
              '';
              restore_immich = writeShellScriptBin "restore_immich" ''
                ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl stop immich-server
                ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl stop immich-machine-learning

                ${pkgs.sudo}/bin/sudo ${restic}/bin/restic -r /mnt/hdd/restic/immich restore latest --target /

                ${scripts.restore_immich_pg}/bin/restore_immich_pg

                ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl start immich-server
                ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl start immich-machine-learning
              '';
            };
          in
          [
            scripts.restore_immich_pg
            scripts.restore_immich
          ];
      };
  };
}
