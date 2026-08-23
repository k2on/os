{ self, config, ... }:
let
  ark = config.ark;
in
{
  ark.services.git =
    {
      pkgs,
      lib,
      config,
      service,
      ...
    }:
    let
      oauthName = "KoonFamily";
      cfg = config.services.gitea;
      themeVersion = "1.26.2";
      giteaGithubTheme = pkgs.stdenvNoCC.mkDerivation {
        pname = "gitea-github-theme";
        version = themeVersion;

        srcs = [
          (pkgs.fetchurl {
            url = "https://github.com/lutinglt/gitea-github-theme/releases/download/v${themeVersion}/theme-github-base.tar.gz";
            hash = "sha256-h4Q1z7AXAckiHyOYR1YX8rsY5+zgVeUv+Wrc0raLH1Q=";
          })
          # optional: GitHub-like layout templates (version-sensitive!)
          (pkgs.fetchurl {
            url = "https://github.com/lutinglt/gitea-github-theme/releases/download/v${themeVersion}/theme-github-templates.tar.gz";
            hash = "sha256-GiZkF8UtIajWTXGvHeXogHJM/M8BrICZQ2AzD+EGyvM=";
          })
          # optional: translations for the templates
          (pkgs.fetchurl {
            url = "https://github.com/lutinglt/gitea-github-theme/releases/download/v${themeVersion}/theme-github-translations.tar.gz";
            hash = "sha256-rFB1cuvbanyGYXM5QncvOglI4LOk1vduJ8osoY131O0=";
          })
        ];

        sourceRoot = ".";
        dontBuild = true;

        installPhase = ''
          mkdir -p $out/public/assets/css
          cp dist/*.css $out/public/assets/css/
          cp -r templates $out/templates
          cp -r dist/options $out/options
        '';
      };
    in
    {
      sops.secrets.git_oidc_client_secret_kanidm = {
        sopsFile = "${self}/secrets/sops/oidc/git.yaml";
        key = "git_oidc_client_secret";
        owner = "kanidm";
      };
      sops.secrets.git_oidc_client_secret = {
        sopsFile = "${self}/secrets/sops/oidc/git.yaml";
        owner = "git";
      };
      sops.secrets.git_runner_token = {
        sopsFile = "${self}/secrets/sops/oidc/git.yaml";
        restartUnits = [ "gitea.service" ];
      };
      sops.templates."gitea-runner.env" = {
        content = ''
          TOKEN=${config.sops.placeholder.git_runner_token}
        '';
        restartUnits = [ "gitea-runner-default.service" ];
      };

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

      networking.firewall.allowedTCPPorts = [ 2222 ];

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
          ui = {
            THEMES = "gitea-auto,gitea-light,gitea-dark,github-auto,github-light,github-dark,github-soft-dark";
            DEFAULT_THEME = "github-auto";
          };
          server = {
            DOMAIN = "git.${ark.mainDomain}";
            ROOT_URL = "https://git.${ark.mainDomain}";
            HTTP_PORT = service.port;
            LANDING_PAGE = "/max";
            SSH_DOMAIN = "ssh.${ark.mainDomain}";
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
          actions.ENABLED = true;
        };
      };

      services.gitea-actions-runner.instances.default = {
        enable = true;
        name = "nixos-host";
        url = config.services.gitea.settings.server.ROOT_URL;
        tokenFile = config.sops.templates."gitea-runner.env".path;
        labels = [ "nix:host" ];
        hostPackages = with pkgs; [
          bash
          coreutils
          curl
          gawk
          gitMinimal
          gnused
          wget
          nodejs # module defaults
          nix # the thing you actually want
        ];
      };

      systemd.services.gitea-runner-default = {
        after = [ "gitea.service" ];
        wants = [ "gitea.service" ];
      };

      users.users.git = {
        isSystemUser = true;
        group = "git";
        home = "/var/lib/gitea";
        description = "Git server (Gitea)";
        createHome = true;
      };
      users.groups.git = { };

      # Link the theme into Gitea's customDir (default: ${stateDir}/custom)
      systemd.tmpfiles.rules = [
        "d ${cfg.customDir}/public 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.customDir}/public/assets 0750 ${cfg.user} ${cfg.group} - -"
        "L+ ${cfg.customDir}/public/assets/css - - - - ${giteaGithubTheme}/public/assets/css"
        "L+ ${cfg.customDir}/templates - - - - ${giteaGithubTheme}/templates"
        "L+ ${cfg.customDir}/options - - - - ${giteaGithubTheme}/options"
      ];

      # Gitea side: seed the token at startup
      systemd.services.gitea.environment.GITEA_RUNNER_REGISTRATION_TOKEN_FILE = "%d/runner-token";
      systemd.services.gitea = {
        serviceConfig = {
          RestartSec = "60"; # Retry every minute
          LoadCredential = [ "runner-token:${config.sops.secrets.git_runner_token.path}" ];
        };
        preStart =
          let
            exe = lib.getExe config.services.gitea.package;

            clientSecretPath = config.sops.secrets."git_oidc_client_secret".path;

            args = lib.escapeShellArgs (
              lib.concatLists [
                [
                  "--name"
                  oauthName
                ]
                [
                  "--provider"
                  "openidConnect"
                ]
                # [ "--key" config.oauth.secrets.git.clientId ]
                [
                  "--auto-discover-url"
                  "https://id.${ark.mainDomain}/oauth2/openid/git/.well-known/openid-configuration"
                ]
                [
                  "--scopes"
                  "email"
                ]
                [
                  "--scopes"
                  "profile"
                ]
                [
                  "--group-claim-name"
                  "groups"
                ]
                [
                  "--admin-group"
                  "admin"
                ]
                [ "--skip-local-2fa" ]
              ]
            );
          in
          lib.mkAfter ''
            CLIENT_ID=git
            CLIENT_SECRET=$(cat ${clientSecretPath})

            provider_id=$(${exe} admin auth list | ${pkgs.gnugrep}/bin/grep -w '${oauthName}' | cut -f1)

            if [[ -z "$provider_id" ]]; then
              ${exe} admin auth add-oauth ${args} --key "$CLIENT_ID" --secret "$CLIENT_SECRET"
            else
              ${exe} admin auth update-oauth --id "$provider_id" ${args} --key "$CLIENT_ID" --secret "$CLIENT_SECRET"
            fi
          '';
      };

      # mkdir -p /var/lib/gitea/custom/public/assets/img/
      #
      # ln -sf ${
      #   ./git/assets/img/logo.svg
      # } /var/lib/gitea/custom/public/assets/img/logo.svg
      # ln -sf ${
      #   ./git/assets/img/favicon.svg
      # } /var/lib/gitea/custom/public/assets/img/favicon.svg
      #
      # mkdir -p /var/lib/gitea/custom/templates/base/
      # ln -sf ${
      #   ./git/templates/base/head_navbar.tmpl
      # } /var/lib/gitea/custom/templates/base/head_navbar.tmpl
      # ln -sf ${
      #   ./git/templates/base/footer_content.tmpl
      # } /var/lib/gitea/custom/templates/base/footer_content.tmpl
      #
      # mkdir -p /var/lib/gitea/custom/templates/custom/
      # ln -sf ${
      #   ./git/templates/custom/header.tmpl
      # } /var/lib/gitea/custom/templates/custom/header.tmpl

      services.restic.backups = {
        git-local = {
          repository = "/mnt/hdd/restic/git";
          passwordFile = config.sops.secrets.restic-password.path;
          initialize = true;
          paths = [
            "/var/lib/gitea/repositories"
            "/var/backup/git"
          ];
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
          paths = [
            "/var/lib/gitea/repositories"
            "/var/backup/git"
          ];
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

      environment.systemPackages =
        with pkgs;
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
        in
        [
          scripts.restore_git_pg
          scripts.restore_git
        ];
    };
}
