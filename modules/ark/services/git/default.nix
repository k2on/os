{ self, config, ... }:
let
  ark = config.ark;
  bot = import ../sivrad/_bot.nix;
in
{
  ark.services.git = {
    aliases = [ "ssh" ];
    oidc = {
      callbacks = [ "/user/oauth2/${ark.oidc.name}/callback" ];
      owner = "git";
      # XXX: PKCE is currently not supported by gitea/forgejo,
      # see https://github.com/go-gitea/gitea/issues/21376.
      pkce = false;
    };
    secrets.git_runner_token = {
      # gitea insists a registration token is exactly 40 characters
      generate = "tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40";
      restartUnits = [ "gitea.service" ];
    };

    backup = {
      paths = [ "/var/lib/gitea/repositories" ];
      postgres = [ "git" ];
      stop = [ "gitea.service" ];
    };

    nixos =
      {
        pkgs,
        lib,
        config,
        service,
        ...
      }:
      let
        cfg = config.services.gitea;
        # Its templates are made for one Gitea version: keep this at the
        # release matching pkgs.gitea (the theme numbers its releases after
        # Gitea's), or pages fail to render.
        themeVersion = "28.0.0";
        giteaGithubTheme = pkgs.stdenvNoCC.mkDerivation {
          pname = "gitea-github-theme";
          version = themeVersion;

          srcs = [
            (pkgs.fetchurl {
              url = "https://github.com/lutinglt/gitea-github-theme/releases/download/v${themeVersion}/theme-github-base.tar.gz";
              hash = "sha256-zs682zLrLgHCV0EJ6ZW3gfN2lN3CoKUVtjtuyFIzGyA=";
            })
            # optional: GitHub-like layout templates (version-sensitive!)
            (pkgs.fetchurl {
              url = "https://github.com/lutinglt/gitea-github-theme/releases/download/v${themeVersion}/theme-github-templates.tar.gz";
              hash = "sha256-GalvJBj5PsWt8LCvMfxeTL+sUALk1bKIxRf1UmlRBZk=";
            })
            # optional: translations for the templates
            (pkgs.fetchurl {
              url = "https://github.com/lutinglt/gitea-github-theme/releases/download/v${themeVersion}/theme-github-translations.tar.gz";
              hash = "sha256-qEbHzbC0dJ8OCf8eXtwi2jUNFemEhWgNSUohIz1qFko=";
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
        # Its access token for the sivrad account (../sivrad/_bot.nix).
        imports = [ (import ./_tokens.nix { mail = bot.mail ark.mainDomain; }) ];

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
              ROOT_URL = "https://git.${ark.mainDomain}";
              HTTP_PORT = service.port;
              LANDING_PAGE = "/max";
              SSH_DOMAIN = "ssh.${ark.mainDomain}";
              SSH_PORT = 2222;
              START_SSH_SERVER = true;
            };
            # For repositories made from now on; an existing one keeps its own
            # switch (Settings > Pull Requests).
            "repository.pull-request".DEFAULT_DELETE_BRANCH_AFTER_MERGE = true;
            # Gitea calls out only to public addresses unless told: the
            # picture it fetches on sign-in (UPDATE_AVATAR, from
            # ark.oidc.picture) is on photos.*, which is ark's own nginx at
            # its tailnet address (arkTailnetIp, ../headscale). Only HTTPS
            # there; a host name alone never covers a private address.
            security.ALLOWED_HOST_LIST = "100.64.0.1/32:443";
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

        # # Link the theme into Gitea's customDir (default: ${stateDir}/custom)
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

              clientSecretPath = service.oidc.clientSecretFile;

              args = lib.escapeShellArgs (
                lib.concatLists [
                  [
                    "--name"
                    service.oidc.name
                  ]
                  [
                    "--provider"
                    "openidConnect"
                  ]
                  # [ "--key" config.oauth.secrets.git.clientId ]
                  [
                    "--auto-discover-url"
                    service.oidc.discovery
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
                    service.oidc.groups.admin.claim
                  ]
                  [ "--skip-local-2fa" ]
                ]
              );
            in
            lib.mkAfter ''
              CLIENT_ID=${service.oidc.clientId}
              CLIENT_SECRET=$(cat ${clientSecretPath})

              provider_id=$(${exe} admin auth list | ${pkgs.gnugrep}/bin/grep -w '${service.oidc.name}' | cut -f1)

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
      };
  };
}
