{ lib, config, pkgs, ... }: {

  services.openssh = {
    enable = true;

    # hostKeys = [
    #   { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    #   { path = "/etc/ssh/ssh_host_rsa_key"; type = "rsa"; bits = 4096; }
    # ];

    settings = {
      # explicitly allow post-quantum KEX
      KexAlgorithms = [
        "mlkem768x25519-sha256"
        "sntrup761x25519-sha512"
        "curve25519-sha256"
      ];
    };
  };

  services.gitea = {
    enable = true;
    user = "git";
    group = "git";
    database = {
      user = "git";
      name = "git";
      type = "postgres";
    };
    settings = {
      server = {
        DOMAIN = "git.koon.us";
        ROOT_URL = "https://git.koon.us";
        HTTP_PORT = 3000;
        LANDING_PAGE = "/max";
        SSH_DOMAIN = "ssh.koon.us";
        SSH_PORT = 2222;
        START_SSH_SERVER = true;
      };
      oauth2_client = {
        ACCOUNT_LINKING = "auto";
        ENABLE_AUTO_REGISTRATION = true;
        UPDATE_AVATAR = true;
        USERNAME = "email";
      };
      service = {
        DISABLE_REGISTRATION = true;
        ENABLE_PASSWORD_SIGNIN_FORM = false;
        ENABLE_PASSKEY_AUTHENTICATION = false;

        SHOW_MILESTONES_DASHBOARD_PAGE = false;
      };
      "service.explore" = {
        DISABLE_USERS_PAGE = true;
        DISABLE_ORGANIZATIONS_PAGE = true;
        DISABLE_CODE_PAGE = true;
      };
    };
  };

  users.users.git = {
    isSystemUser = true;
    group = "git";
    home = "/var/lib/gitea";
    description = "Git server (Gitea)";
    createHome = true;
  };
  users.groups.git = { };

  systemd.services.gitea = {
    serviceConfig = {
      RestartSec = "60"; # Retry every minute
    };
    preStart = let
      exe = lib.getExe config.services.gitea.package;

      clientIdPath = config.sops.secrets."git/clientId".path;
      clientSecretPath = config.sops.secrets."git/clientSecret".path;

      args = lib.escapeShellArgs (lib.concatLists [
        [ "--name" config.oauth.name ]
        [ "--provider" "openidConnect" ]
        # [ "--key" config.oauth.secrets.git.clientId ]
        [
          "--auto-discover-url"
          "https://auth.koon.us/.well-known/openid-configuration"
        ]
        [ "--scopes" "email" ]
        [ "--scopes" "profile" ]
        [ "--group-claim-name" "groups" ]
        [ "--admin-group" "admin" ]
        [ "--skip-local-2fa" ]
      ]);
    in lib.mkAfter ''
      CLIENT_ID=$(cat ${clientIdPath})
      CLIENT_SECRET=$(cat ${clientSecretPath})

      provider_id=$(${exe} admin auth list | ${pkgs.gnugrep}/bin/grep -w '${config.oauth.name}' | cut -f1)

      if [[ -z "$provider_id" ]]; then
        ${exe} admin auth add-oauth ${args} --key "$CLIENT_ID" --secret "$CLIENT_SECRET"
      else
        ${exe} admin auth update-oauth --id "$provider_id" ${args} --key "$CLIENT_ID" --secret "$CLIENT_SECRET"
      fi

      mkdir -p /var/lib/gitea/custom/public/assets/img/

      ln -sf ${
        ./git/assets/img/logo.svg
      } /var/lib/gitea/custom/public/assets/img/logo.svg
      ln -sf ${
        ./git/assets/img/favicon.svg
      } /var/lib/gitea/custom/public/assets/img/favicon.svg

      mkdir -p /var/lib/gitea/custom/templates/base/
      ln -sf ${
        ./git/templates/base/head_navbar.tmpl
      } /var/lib/gitea/custom/templates/base/head_navbar.tmpl
      ln -sf ${
        ./git/templates/base/footer_content.tmpl
      } /var/lib/gitea/custom/templates/base/footer_content.tmpl

      mkdir -p /var/lib/gitea/custom/templates/custom/
      ln -sf ${
        ./git/templates/custom/header.tmpl
      } /var/lib/gitea/custom/templates/custom/header.tmpl

    '';
  };

  services.restic.backups = {
    git-local = {
      repository = "/mnt/hdd/restic/git";
      passwordFile = config.sops.secrets.restic-password.path;
      initialize = true;
      paths = [ "/var/lib/gitea/repositories" "/var/backup/git" ];
      backupPrepareCommand = ''
        mkdir -p /var/backup/git

        ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl stop gitea

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql}/bin/pg_dump \
          --clean \
          --if-exists \
          --dbname=git > /var/backup/git/postgres.sql
      '';
      backupCleanupCommand = ''
        ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl start gitea
      '';
    };
    git-remote = {
      repository = "rest:http://m1:8000/git";
      passwordFile = config.sops.secrets.restic-password.path;
      initialize = true;
      paths = [ "/var/lib/gitea/repositories" "/var/backup/git" ];
      backupPrepareCommand = ''
        mkdir -p /var/backup/git

        ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl stop gitea

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql}/bin/pg_dump \
          --clean \
          --if-exists \
          --dbname=git > /var/backup/git/postgres.sql
      '';
      backupCleanupCommand = ''
        ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl start gitea
      '';
    };
  };

  environment.systemPackages = with pkgs;
    let
      scripts = with pkgs; {
        restore_git_pg = writeShellScriptBin "restore_git_pg" ''
          ${pkgs.sudo}/bin/sudo -u postgres psql --dbname=git < /var/backup/git/postgres.sql
        '';
        restore_git = writeShellScriptBin "restore_git" ''
          ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl stop gitea

          ${pkgs.sudo}/bin/sudo ${restic}/bin/restic -r /mnt/hdd/restic/git restore latest --target /

          ${scripts.restore_git_pg}/bin/restore_git_pg

          ${pkgs.sudo}/bin/sudo ${pkgs.systemd}/bin/systemctl start gitea
        '';
      };
    in [ scripts.restore_git_pg scripts.restore_git ];
}
