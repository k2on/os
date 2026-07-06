{ ... }: {
  ark.services.photos = { config, lib, pkgs, service, ... }: 
  let 
    oauthName = "KoonFamily";
  in {
    sops = {
      templates = {
        "immich-config.json" = {
          content = builtins.toJSON {
            passwordLogin.enabled = false;

            # We will do this ourselves
            backup.database.enabled = false;

            oauth = {
              enabled = true;
              autoLaunch = true;
              autoRegister = true;
              buttonText =
                lib.strings.concatStrings [ "Login To " oauthName ];
              clientId = config.sops.placeholder."oauth/photos/clientId";
              clientSecret = config.sops.placeholder."oauth/photos/clientSecret";
              issuerUrl = "https://auth.koon.us/.well-known/openid-configuration";
            };
          };
          owner = config.users.users.immich.name;
          mode = "0400";
          restartUnits = [ "immich-server.service" "pocket-id.service" ];
        };
      };
    };

    services.immich = {
      enable = true;
      port = service.port;
      environment.IMMICH_CONFIG_FILE = config.sops.templates."immich-config.json".path;
      accelerationDevices = null;

      machine-learning.environment = {
        HF_XET_CACHE = "/var/cache/immich/huggingface-xet";
      };

    };

    users.users.immich = {
      home = "/var/lib/immich";
      createHome = true;
      extraGroups = [ "video" "render" ];
    };

    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [ intel-media-driver ];
    };
    environment.sessionVariables = { LIBVA_DRIVER_NAME = "iHD"; };

    services.restic.backups = {
      immich-local = {
        repository = "/mnt/hdd/restic/immich";
        passwordFile = config.sops.secrets.restic-password.path;
        initialize = true;
        paths = [ "/var/lib/immich/upload" "/var/backup/immich" ];
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
        paths = [ "/var/lib/immich/upload" "/var/backup/immich" ];
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

    environment.systemPackages = with pkgs;
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
      in [ scripts.restore_immich_pg scripts.restore_immich ];
  };
}
