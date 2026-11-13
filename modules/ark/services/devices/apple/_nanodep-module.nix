# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# services.nanodep: micromdm's NanoDEP (./_nanodep.nix), the client for
# Apple's Automated Device Enrollment, run declaratively. Each DEP name is
# one "MDM server" in Apple Business Manager, with:
#
#   - tokenPKI: the key pair whose certificate is uploaded to ABM, given
#     here rather than made by depserver (so it can live in a secret), and
#     put in depserver's staging slot on every start;
#   - tokenFile: the encrypted token ABM gives back (the .p7m), uploaded to
#     depserver, which decrypts it with that key;
#   - profile: the ADE profile, defined at Apple whenever it changes, set
#     as the one depsyncer gives every device newly assigned to the server,
#     and assigned to the serial numbers in `devices`.
#
# depsyncer follows each name's devices every syncInterval seconds.
#
# Written with nothing of ark in it, to go to nixpkgs one day (with
# pkgs.nanodep there).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nanodep;
  api = "http://${cfg.listenAddress}:${toString cfg.port}";
  # filekv keeps each key as a file of its own here.
  kvDir = "${cfg.storage.dsn}/dep_names";

  withPKI = lib.filterAttrs (_: n: n.tokenPKI != null) cfg.names;
  needsSync = lib.any (n: n.tokenFile != null || n.profile != null) (lib.attrValues cfg.names);

  nameState = lib.mapAttrs (
    _: n:
    pkgs.writeText "nanodep-profile.json" (
      builtins.toJSON (
        lib.optionalAttrs (n.profile != null) n.profile
        // {
          inherit (n) devices;
        }
      )
    )
  ) cfg.names;

  sync = pkgs.writeShellApplication {
    name = "nanodep-sync";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
    text = ''
      auth="depserver:$(cat "$CREDENTIALS_DIRECTORY/api-key")"
      call() { curl -fsS -u "$auth" "$@"; }
      # The profile last defined for each name, and what it was defined from.
      state=/var/lib/nanodep-sync
      for _ in $(seq 60); do curl -fsS ${api}/version >/dev/null && break; sleep 1; done

      ${lib.concatStrings (
        lib.mapAttrsToList (name: n: ''
          echo "${name}:"
          ${lib.optionalString (n.tokenFile != null) ''
            call -X PUT -T "$CREDENTIALS_DIRECTORY/token-${name}" ${api}/v1/tokenpki/${name} >/dev/null
            echo "  token uploaded"
          ''}
          ${lib.optionalString (n.profile != null) ''
            want=$(jq -c 'del(.devices)' ${nameState.${name}} | sha256sum | cut -d' ' -f1)
            uuid=$(cat "$state/${name}.uuid" 2>/dev/null || true)
            if [ "$(cat "$state/${name}.hash" 2>/dev/null || true)" != "$want" ] || [ -z "$uuid" ]; then
              # Defined with the devices in it: assigned in the same call.
              uuid=$(call -X POST -H 'Content-Type: application/json;charset=UTF8' \
                --data-binary @${nameState.${name}} ${api}/proxy/${name}/profile | jq -er .profile_uuid)
              echo "$uuid" > "$state/${name}.uuid"
              echo "$want" > "$state/${name}.hash"
              echo "  profile defined: $uuid"
            elif [ "$(jq '.devices | length' ${nameState.${name}})" -gt 0 ]; then
              jq -c --arg u "$uuid" '{profile_uuid: $u, devices}' ${nameState.${name}} \
                | call -X POST -H 'Content-Type: application/json;charset=UTF8' --data-binary @- \
                    ${api}/proxy/${name}/profile/devices \
                | jq -c '.devices'
            fi
            ${lib.optionalString n.assignNewDevices ''
              call -X PUT "${api}/v1/assigner/${name}?profile_uuid=$uuid" >/dev/null
            ''}
          ''}
        '') cfg.names
      )}
    '';
  };

  fileType = lib.types.path;

  nameType = lib.types.submodule {
    options = {
      tokenPKI = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              certFile = lib.mkOption {
                type = fileType;
                description = "PEM certificate uploaded to ABM for this MDM server. May be the same file as keyFile.";
              };
              keyFile = lib.mkOption {
                type = fileType;
                description = "Its RSA private key, PEM.";
              };
            };
          }
        );
        default = null;
        description = ''
          The key pair ABM encrypts this server's token to. Put in
          depserver's staging slot before it starts (filekv storage only);
          null to make one with depserver's /v1/tokenpki API instead.
        '';
      };

      tokenFile = lib.mkOption {
        type = lib.types.nullOr fileType;
        default = null;
        description = "The encrypted token from ABM (the .p7m download), uploaded on every start.";
      };

      profile = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        example = {
          profile_name = "Example";
          url = "https://mdm.example.com/enroll";
          is_supervised = true;
          is_mdm_removable = false;
          await_device_configured = false;
          skip_setup_items = [ "Android" ];
        };
        description = ''
          The ADE profile (Apple's "Profile" object, without `devices`).
          Defined at Apple again only when it changes.
        '';
      };

      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Serial numbers to assign the profile to.";
      };

      assignNewDevices = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Make the profile depsyncer's assigner: every device newly assigned to this server in ABM gets it.";
      };
    };
  };
in
{
  options.services.nanodep = {
    enable = lib.mkEnableOption "NanoDEP, the client for Apple's Automated Device Enrollment";

    package = lib.mkPackageOption pkgs "nanodep" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nanodep";
      description = "User depserver and depsyncer run as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nanodep";
      description = "Group depserver and depsyncer run as.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address depserver listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9001;
      description = "Port depserver listens on.";
    };

    storage = {
      backend = lib.mkOption {
        type = lib.types.enum [
          "filekv"
          "mysql"
          "pgsql"
          "inmem"
        ];
        default = "filekv";
        description = "Storage backend, shared by depserver and depsyncer.";
      };
      dsn = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/nanodep/db";
        description = "Data source: the directory for `filekv`, the connection string otherwise.";
      };
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "File with depserver's API key: HTTP basic auth as user `depserver`.";
    };

    syncInterval = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1800;
      description = "Seconds between depsyncer's syncs with Apple.";
    };

    names = lib.mkOption {
      type = lib.types.attrsOf nameType;
      default = { };
      description = "DEP names: one per MDM server in Apple Business Manager.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = withPKI != { } -> cfg.storage.backend == "filekv";
        message = "services.nanodep: tokenPKI is put straight into filekv storage.";
      }
    ];

    users.users = lib.mkIf (cfg.user == "nanodep") {
      nanodep = {
        isSystemUser = true;
        inherit (cfg) group;
      };
    };
    users.groups = lib.mkIf (cfg.group == "nanodep") { nanodep = { }; };

    systemd.services =
      let
        hardening = {
          User = cfg.user;
          Group = cfg.group;
          StateDirectory = "nanodep";
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/nanodep";
          Restart = "on-failure";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          NoNewPrivileges = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
        storageArgs = [
          "-storage"
          cfg.storage.backend
          "-storage-dsn"
          cfg.storage.dsn
        ];
      in
      {
        depserver = {
          description = "NanoDEP server";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = hardening // {
            LoadCredential = [
              "api-key:${cfg.apiKeyFile}"
            ]
            ++ lib.concatLists (
              lib.mapAttrsToList (name: n: [
                "pki-cert-${name}:${n.tokenPKI.certFile}"
                "pki-key-${name}:${n.tokenPKI.keyFile}"
              ]) withPKI
            );
            ExecStart = pkgs.writeShellScript "depserver-start" ''
              set -eu
              umask 077
              ${lib.optionalString (withPKI != { }) "mkdir -p ${kvDir}"}
              ${lib.concatStrings (
                lib.mapAttrsToList (name: _: ''
                  ${lib.getExe pkgs.openssl} x509 -in "$CREDENTIALS_DIRECTORY/pki-cert-${name}" -out ${kvDir}/cert_staging.${name}
                  # PKCS#1 ("RSA PRIVATE KEY"): depserver reads no other.
                  ${lib.getExe pkgs.openssl} pkey -traditional -in "$CREDENTIALS_DIRECTORY/pki-key-${name}" -out ${kvDir}/key_staging.${name}
                '') withPKI
              )}
              NANODEP_API=$(cat "$CREDENTIALS_DIRECTORY/api-key")
              export NANODEP_API
              exec ${
                lib.escapeShellArgs (
                  [
                    "${cfg.package}/bin/depserver"
                    "-listen"
                    "${cfg.listenAddress}:${toString cfg.port}"
                  ]
                  ++ storageArgs
                )
              }
            '';
          };
        };

        depsyncer = lib.mkIf (cfg.names != { }) {
          description = "NanoDEP device syncer";
          wantedBy = [ "multi-user.target" ];
          # After the token is in: before that it has nothing to sync with.
          after = [
            "network-online.target"
            "nanodep-sync.service"
          ];
          wants = [ "network-online.target" ];
          serviceConfig = hardening // {
            ExecStart = lib.escapeShellArgs (
              [
                "${cfg.package}/bin/depsyncer"
                "-duration"
                (toString cfg.syncInterval)
              ]
              ++ storageArgs
              ++ lib.attrNames cfg.names
            );
            # The first sync may come before the token is uploaded.
            RestartSec = 60;
          };
        };

        nanodep-sync = lib.mkIf needsSync {
          description = "Give NanoDEP its tokens and ADE profiles from the configuration";
          wantedBy = [ "multi-user.target" ];
          requires = [ "depserver.service" ];
          after = [ "depserver.service" ];
          partOf = [ "depserver.service" ];
          restartTriggers = [ sync ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            DynamicUser = true;
            StateDirectory = "nanodep-sync";
            LoadCredential = [
              "api-key:${cfg.apiKeyFile}"
            ]
            ++ lib.mapAttrsToList (name: n: "token-${name}:${n.tokenFile}") (
              lib.filterAttrs (_: n: n.tokenFile != null) cfg.names
            );
            ExecStart = lib.getExe sync;
          };
        };
      };
  };
}
