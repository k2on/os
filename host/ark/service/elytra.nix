{ secrets, config, pkgs, elytrarides, ... }:

{
  users.users.elytra-web = {
    isSystemUser = true;
    group = "elytra-web";
    description = "Elytra Rides web service user";
  };

  users.users.backend = {
    isSystemUser = true;
    home = "/var/lib/elytra-backend";
    createHome = true;
    group = "backend";
  };
  
  users.groups.elytra-web = {};
  users.groups.backend = {};

  systemd.services.elytra-web = {
    description = "Elytra Rides Next.js Web Application";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    
    environment = {
      PORT = "3007";
      HOST = "127.0.0.1";
      NODE_ENV = "production";
    };

    serviceConfig = {
      Type = "simple";
      User = "elytra-web";
      Group = "elytra-web";

      WorkingDirectory = "${pkgs.web}/lib/node_modules/web";
      ExecStart =
        "${pkgs.nodejs}/bin/node ${pkgs.web}/lib/node_modules/web/node_modules/next/dist/bin/next start";
      EnvironmentFile = config.sops.secrets."elytra-frontend-env".path;

      Restart = "on-failure";
      RestartSec = 10;

      # Security hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      
      StateDirectory = "elytra-web";
      StateDirectoryMode = "0750";
      
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "elytra-web";
    };
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "backend" ];
    ensureUsers = [
      {
        name = "backend";
        ensureDBOwnership = true;
      }
    ];
  };
  services.redis = {
    enable = true;
  };

  nixpkgs.overlays = [
    (final: prev: {
      web = elytrarides.packages.${pkgs.system}.web.overrideAttrs (old: {
        buildPhase = ''
          export NEXT_PUBLIC_GOOGLE_MAPS_API_KEY="${config.environment.sessionVariables.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY}"
          ${old.buildPhase or "runHook preBuild; npm run build --if-present; runHook postBuild"}
        '';
      });
    })
  ];

  environment.sessionVariables.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = secrets.ark.elytra.google-maps-api-key;

  systemd.services.elytra-backend = {
    description = "Elytra Rides Backend Service";
    after = [ "network.target" "postgresql.service" ];
    wants = [ "network-online.target" ];

    serviceConfig = {

      ExecStart = "${elytrarides.packages.${pkgs.system}.backend}/bin/nujade_backend";
      ExecStartPre = [
        "${pkgs.diesel-cli}/bin/diesel --database-url=\"postgresql:///backend?user=backend\" migration run --migration-dir=${elytrarides.packages.${pkgs.system}.backend}/migrations"
      ];

      Restart = "always";
      RestartSec = 5;
      User = "backend";
      WorkingDirectory = "/var/lib/elytra-backend";
      Environment = "RUST_LOG=info";
      EnvironmentFile = config.sops.secrets."elytra-backend-env".path;
    };

    environment = {
      DATABASE_URL="postgresql:///backend?user=backend";
    };

    wantedBy = [ "multi-user.target" ];
  };
}
