{ pkgs, config, ... }:

  let

  src = pkgs.fetchgit {
    url = "https://git.koon.us/max/money.git";
    hash = "sha256-TPUeYuffR8U0M3Wnc3yGmqDhEjWIhRRFaKDkhTBsNG8=";
  };

  expoWeb = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "expo-web";
    version = "1.0.0";
    src = src;
    pnpm = pkgs.pnpm_10;
    nativeBuildInputs = [
      pkgs.nodejs
      finalAttrs.pnpm.configHook
    ];
    pnpmDeps = finalAttrs.pnpm.fetchDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 2;
      hash = "sha256-x2zCFeMU0VfkVRILrLReEOFNrcd7aJp57v4fMGBE2dI=";
    };
    pnpmInstallFlags = [ "--frozen-lockfile" ];
    buildPhase = ''
      runHook preBuild
      pnpm run build
      runHook postBuild
    '';

    installPhase = ''
      mkdir -p $out
      cp -r dist/* $out/
    '';
  });

  api = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "koon-money-api";
    version = "1.0.1";
    src = src;
    pnpm = pkgs.pnpm_10;
    nativeBuildInputs = [
      pkgs.nodejs
      finalAttrs.pnpm.configHook
      pkgs.python3  # Required for node-gyp
      pkgs.nodePackages.node-gyp  # For building native modules
      pkgs.pkg-config
      pkgs.gnumake
      pkgs.gcc
    ];
    buildInputs = [
      pkgs.sqlite
      pkgs.sqlite.dev
      pkgs.readline
      pkgs.ncurses
      pkgs.libbsd
    ];
    pnpmDeps = finalAttrs.pnpm.fetchDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 2;
      hash = "sha256-x2zCFeMU0VfkVRILrLReEOFNrcd7aJp57v4fMGBE2dI=";
    };
    NIX_CFLAGS_COMPILE = "-D_GNU_SOURCE";
    pnpmInstallFlags = [ "--frozen-lockfile" ];

    buildPhase = ''
      runHook preBuild
      cd node_modules/@rocicorp/zero-sqlite3
      node-gyp rebuild --build-from-source
      cd -
      runHook postBuild
    '';

    installPhase = ''
      mkdir -p $out
      cp -r . $out/
    '';
  });

  api-port = "3161";
  in
{

  services.nginx = {
    enable = true;

    virtualHosts."money.koon.us" = {
      root = "${expoWeb}";
      listen = [
        { addr = "127.0.0.1"; port = 3160; }
      ];
      locations."/" = {
        tryFiles = "$uri /index.html";
      };
    };

  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      zero = {
        image = "rocicorp/zero:0.23.2025101600";
        ports = ["127.0.0.1:4848:4848"];
        volumes = [ "/run/postgresql:/run/postgresql" ];
        environment = {

          ZERO_UPSTREAM_DB = "postgresql://postgres@127.0.0.1/money";
          ZERO_REPLICA_FILE = "/tmp/zync-replica.db";
          ZERO_GET_QUERIES_URL = "http://localhost:${api-port}/api/zero/get-queries";
          ZERO_GET_QUERIES_FORWARD_COOKIES = "true";

          ZERO_MUTATE_URL = "http://localhost:${api-port}/api/zero/mutate";
          ZERO_MUTATE_FORWARD_COOKIES = "true";
        };
        extraOptions = [ "--network=host" ];
      };
    };
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "money" ];
    ensureUsers = [
      {
        name = "money";
        ensureDBOwnership = true;
      }
    ];
    authentication = ''
      # TYPE  DATABASE  USER     ADDRESS        METHOD
      local   all       postgres               peer
      host    all       all     127.0.0.1/32   trust
      host    all       all     ::1/128        trust
    '';
    settings = {
      wal_level = "logical";
    };
  };

  systemd.services.money-api = {
    description = "Money API";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    
    environment = {
      ZERO_UPSTREAM_DB = "postgresql://postgres@127.0.0.1/money";
      PORT = api-port;
      NODE_ENV = "production";
      BETTER_AUTH_SECRET = "burger";
      DEBUG = "*";
      NODE_OPTIONS = "--trace-warnings --trace-uncaught";
      OAUTH_DISCOVERY_URL = "https://auth.koon.us/.well-known/openid-configuration";
      PLAID_ENV = "production";
    };

    serviceConfig = {
      Type = "simple";
      User = "money";
      Group = "money";
      WorkingDirectory = "${api}/shared";

      ExecStartPre = "${api}/node_modules/.bin/drizzle-kit push --config=${api}/shared/drizzle.config.ts";

      ExecStart = pkgs.writeShellScript "money-api-start" ''
        set -euo pipefail

        export OAUTH_CLIENT_ID="$(cat ${config.sops.secrets."money/clientId".path})"
        export OAUTH_CLIENT_SECRET="$(cat ${config.sops.secrets."money/clientSecret".path})"

        exec ${api}/node_modules/.bin/tsx ${api}/api/src/index.ts
      '';

      EnvironmentFile = config.sops.secrets."money-env".path;

      Restart = "on-failure";
      RestartSec = 10;

      SyslogIdentifier = "money-api";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };



  users.users.money = {
    isSystemUser = true;
    home = "/var/lib/money";
    createHome = true;
    group = "money";
  };
  
  users.groups.money = {};



}

