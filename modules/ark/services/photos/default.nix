{ self, config, ... }:
let
  ark = config.ark;
  shareDomain = "share.${ark.mainDomain}";
  domain = ark.serviceDomain "photos" ark.services.photos;
in
{
  # Shared albums are public through immich-public-proxy on share.*: it
  # answers only for links Immich has shared, from Immich's own API, so
  # Immich itself stays on the tailnet. The vps passes share.* through to
  # ark's nginx (lib/public.nix).
  ark.public.share = 443;

  # Everyone's profile picture is the one they set in Immich, at
  # /avatar/<username> here (on the tailnet, like Immich), and that is the
  # `picture` claim every service gets from Kanidm (lib/oidc.nix).
  # photos-avatars (./avatars) copies the pictures out of Immich as they
  # change, as PNG whatever Immich keeps, watching Immich's database: no API
  # key, and nginx serves plain files, so a person without one is a 404 and
  # every app shows its own.
  ark.oidc.picture = "https://${domain}/avatar/{name}";

  perSystem =
    { pkgs, ... }:
    let
      photos-avatars = pkgs.callPackage ../../_rust.nix { pname = "photos-avatars"; };
    in
    {
      packages = { inherit photos-avatars; };
      # Immich's Postgres on adam is 16.
      checks.photos-avatars = pkgs.callPackage ./avatars/_check.nix {
        inherit photos-avatars;
        postgresql = pkgs.postgresql_16;
      };
    };

  ark.services.photos = {
    oidc.callbacks = [
      "/auth/login"
      "app.immich:///oauth-callback"
    ];

    backup = {
      name = "immich";
      paths = [ "/var/lib/immich/upload" ];
      postgres = [ "immich" ];
      stop = [
        "immich-server.service"
        "immich-machine-learning.service"
      ];
    };

    nixos =
      {
        config,
        lib,
        pkgs,
        service,
        ...
      }:
      let
        # The long poll devices keep their copy with (./avatars/src/http.rs,
        # modules/aspects/avatar.nix); after Immich and its public proxy.
        avatarsPort = service.port + 2;
      in
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

        # As the immich user: its role in Postgres by peer authentication,
        # and its files, which only it may read.
        systemd.services.photos-avatars =
          let
            photosAvatars = pkgs.callPackage ../../_rust.nix { pname = "photos-avatars"; };
            avatars = (pkgs.formats.json { }).generate "photos-avatars.json" {
              socket = config.services.immich.database.host;
              database = config.services.immich.database.name;
              user = config.services.immich.database.user;
              dir = "/var/lib/photos-avatars";
              recheckSeconds = 3600;
              listen = "127.0.0.1:${toString avatarsPort}";
              # PNGs of other kinds, and pictures cropped to a circle for devices
              # that ask (the avatar aspect does).
              magick = lib.getExe' pkgs.imagemagick "magick";
              persons = lib.mapAttrsToList (name: p: {
                inherit name;
                inherit (p) mail;
              }) ark.persons;
            };
          in
          {
            description = "Immich profile pictures, by username";
            # After Immich's migrations, which make the table it watches.
            after = [
              "postgresql.service"
              "immich-server.service"
            ];
            requires = [ "postgresql.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${lib.getExe photosAvatars} ${avatars}";
              User = config.services.immich.user;
              Group = config.services.immich.group;
              StateDirectory = "photos-avatars";
              StateDirectoryMode = "0755";
              Restart = "always";
              RestartSec = 5;
              # The long poll, for nginx on loopback.
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
              ];
              IPAddressAllow = "localhost";
              IPAddressDeny = "any";
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              NoNewPrivileges = true;
            };
          };

        services.nginx.virtualHosts.${service.domain}.locations = {
          "~ ^/avatar/(?<person>[a-z0-9_-]+)$" = {
            root = "/var/lib/photos-avatars";
            tryFiles = "/$person.png =404";
            # Apps copy it when someone signs in; browsers may keep it a while.
            extraConfig = ''
              expires 10m;
            '';
          };
          "~ ^/avatar/[a-z0-9_-]+/wait$" = {
            proxyPass = "http://127.0.0.1:${toString avatarsPort}";
            # A request is held until the picture changes, up to 50 minutes.
            extraConfig = ''
              proxy_read_timeout 3600s;
              proxy_buffering off;
            '';
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
      };
  };
}
