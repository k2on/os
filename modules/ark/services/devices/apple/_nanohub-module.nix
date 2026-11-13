# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# services.nanohub: micromdm's NanoHUB (./_nanohub.nix), an MDM server for
# Apple devices, run declaratively. Besides the server itself:
#
#   - pushCertificate: the APNs certificate from Apple, uploaded to it on
#     every start (and whenever the files change);
#   - declarations, sets and enrollmentSets: declarative device management
#     (KMFDDM), made to match on every start and every change — what is
#     declared is added, what is not is removed;
#   - enrollmentProfile: the .mobileconfig a device installs to enroll,
#     built from the push certificate (its topic) and a SCEP server (the
#     device's identity; services.scep), optionally signed.
#
# Written with nothing of ark in it, to go to nixpkgs one day (with
# pkgs.nanohub there).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nanohub;
  profile = cfg.enrollmentProfile;
  openssl = lib.getExe pkgs.openssl;
  api = "http://${
    if cfg.listenAddress == "" then "127.0.0.1" else cfg.listenAddress
  }:${toString cfg.port}";

  managesDDM = cfg.declarations != { } || cfg.sets != { } || cfg.enrollmentSets != { };
  needsSync = managesDDM || cfg.pushCertificate != null;

  # A stable UUID per payload, so installing a new profile replaces the old.
  uuid =
    name:
    let
      h = builtins.hashString "sha256" "${profile.identifier}.${name}";
      s = start: len: lib.substring start len h;
    in
    lib.toUpper "${s 0 8}-${s 8 4}-4${s 13 3}-8${s 17 3}-${s 20 12}";

  # @TOPIC@ and @CHALLENGE@ are filled in when it is built.
  profilePlist = pkgs.writeText "enroll.plist" (
    lib.generators.toPlist { escape = true; } {
      PayloadType = "Configuration";
      PayloadVersion = 1;
      PayloadIdentifier = profile.identifier;
      PayloadUUID = uuid "profile";
      PayloadDisplayName = profile.displayName;
      PayloadDescription = profile.description;
      PayloadOrganization = profile.organization;
      PayloadScope = "System";
      PayloadContent = [
        {
          PayloadType = "com.apple.security.scep";
          PayloadVersion = 1;
          PayloadIdentifier = "${profile.identifier}.scep";
          PayloadUUID = uuid "scep";
          PayloadDisplayName = "Device identity";
          PayloadContent = {
            URL = profile.scep.url;
            Subject = map (rdn: [ rdn ]) profile.scep.subject;
            Keysize = profile.scep.keySize;
            "Key Type" = "RSA";
            # Signing and encryption.
            "Key Usage" = 5;
          }
          // lib.optionalAttrs (profile.scep.challengeFile != null) { Challenge = "@CHALLENGE@"; };
        }
        (
          {
            PayloadType = "com.apple.mdm";
            PayloadVersion = 1;
            PayloadIdentifier = "${profile.identifier}.mdm";
            PayloadUUID = uuid "mdm";
            PayloadDisplayName = "Device management";
            IdentityCertificateUUID = uuid "scep";
            Topic = "@TOPIC@";
            ServerURL = profile.serverURL;
            # The device's identity in the Mdm-Signature header, which
            # nanohub reads unless -cert-header says otherwise: works
            # behind any TLS-terminating proxy.
            SignMessage = true;
            AccessRights = profile.accessRights;
            CheckOutWhenRemoved = true;
            ServerCapabilities = [ "com.apple.mdm.per-user-connections" ];
          }
          // lib.optionalAttrs (profile.checkInURL != null) { CheckInURL = profile.checkInURL; }
        )
      ]
      ++ profile.extraPayloads;
    }
  );

  # What nanohub-sync makes nanohub's DDM match.
  ddmState = pkgs.writeText "nanohub-ddm.json" (
    builtins.toJSON {
      declarations = lib.mapAttrsToList (id: d: {
        Identifier = id;
        Type = d.type;
        Payload = d.payload;
      }) cfg.declarations;
      inherit (cfg) sets enrollmentSets;
    }
  );

  sync = pkgs.writeShellApplication {
    name = "nanohub-sync";
    runtimeInputs = with pkgs; [
      curl
      jq
    ];
    text = ''
      auth="nanohub:$(cat "$CREDENTIALS_DIRECTORY/api-key")"
      ddm=${api}/api/v1/ddm
      state=${ddmState}
      call() { curl -fsS -u "$auth" "$@"; }
      # A list from the API, one per line; null (none) is nothing.
      list() { call "$1" | jq -r '.[]?'; }
      has() { grep -qxF -- "$1"; }

      for _ in $(seq 60); do curl -fsS ${api}/version >/dev/null && break; sleep 1; done

      ${lib.optionalString (cfg.pushCertificate != null) ''
        cat "$CREDENTIALS_DIRECTORY/push.crt" "$CREDENTIALS_DIRECTORY/push.key" \
          | call -X PUT -T - ${api}/api/v1/nanomdm/pushcert >/dev/null
      ''}

      ${lib.optionalString managesDDM ''
        jq -c '.declarations[]' "$state" | while read -r d; do
          call -X PUT --data-binary "$d" "$ddm/declarations" >/dev/null
        done

        # Every set, declared or not: one no longer declared is emptied.
        for set in $( (jq -r '.sets | keys[]' "$state"; list "$ddm/sets") | sort -u); do
          want=$(jq -r --arg s "$set" '.sets[$s][]?' "$state")
          have=$(list "$ddm/set-declarations/$set")
          for d in $want; do
            has "$d" <<<"$have" || call -X PUT "$ddm/set-declarations/$set?declaration=$d"
          done
          for d in $have; do
            has "$d" <<<"$want" || call -X DELETE "$ddm/set-declarations/$set?declaration=$d"
          done
        done

        want=$(jq -r '.declarations[].Identifier' "$state")
        for d in $(list "$ddm/declarations"); do
          has "$d" <<<"$want" || call -X DELETE "$ddm/declarations/$d"
        done

        # Enrollments: only the ones declared. One left out keeps its sets.
        jq -r '.enrollmentSets | keys[]' "$state" | while read -r id; do
          want=$(jq -r --arg i "$id" '.enrollmentSets[$i][]' "$state")
          have=$(list "$ddm/enrollment-sets/$id")
          for s in $want; do
            has "$s" <<<"$have" || call -X PUT "$ddm/enrollment-sets/$id?set=$s"
          done
          for s in $have; do
            has "$s" <<<"$want" || call -X DELETE "$ddm/enrollment-sets/$id?set=$s"
          done
        done
      ''}
    '';
  };

  buildProfile = pkgs.writeShellApplication {
    name = "nanohub-enrollment-profile";
    runtimeInputs = [ pkgs.openssl ];
    text = ''
      creds=$CREDENTIALS_DIRECTORY
      topic=$(openssl x509 -noout -subject -nameopt sep_multiline,sname -in "$creds/push.crt" \
        | sed -n 's/^ *UID=//p')
      ${
        if profile.scep.challengeFile != null then
          ''challenge=$(sed 's/[\/&]/\\&/g' "$creds/challenge")''
        else
          "challenge="
      }
      out=${profile.path}
      sed -e "s/@TOPIC@/$topic/" -e "s/@CHALLENGE@/$challenge/" ${profilePlist} > "$out.plist"
      ${
        if profile.signing != null then
          ''
            openssl cms -sign -nodetach -binary -outform DER -in "$out.plist" -out "$out.tmp" \
              -signer "$creds/sign.crt" -inkey "$creds/sign.key" \
              ${lib.optionalString (profile.signing.chainFile != null) ''-certfile "$creds/sign.chain"''}
            rm "$out.plist"
          ''
        else
          ''mv "$out.plist" "$out.tmp"''
      }
      chmod 0640 "$out.tmp"
      mv "$out.tmp" "$out"
    '';
  };

  declarationType = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type = lib.types.str;
        example = "com.apple.configuration.passcode.settings";
        description = "The declaration's Type.";
      };
      payload = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "The declaration's Payload.";
      };
    };
  };

  fileType = lib.types.path;
in
{
  options.services.nanohub = {
    enable = lib.mkEnableOption "NanoHUB, an MDM server for Apple devices";

    package = lib.mkPackageOption pkgs "nanohub" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nanohub";
      description = "User the server runs as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nanohub";
      description = "Group the server runs as.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address to listen on. Devices talk to /mdm (and /checkin with -checkin); put TLS in front.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9004;
      description = "Port to listen on.";
    };

    storage = {
      backend = lib.mkOption {
        type = lib.types.enum [
          "file"
          "mysql"
          "inmem"
        ];
        default = "file";
        description = "Storage backend.";
      };
      dsn = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/nanohub/db";
        description = "Data source: the directory for `file`, the connection string for `mysql`.";
      };
    };

    caFile = lib.mkOption {
      type = lib.types.nullOr fileType;
      default = null;
      description = ''
        PEM file with the CA certificate(s) that issue device identities
        (services.scep's), which nanohub checks every request against.
        Other blocks in it, like the CA's key, are ignored.
      '';
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr fileType;
      default = null;
      description = ''
        File with the API key: HTTP basic auth as user `nanohub` on
        /api/v1/. Required for pushCertificate and declarative management.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "-checkin"
        "-debug"
      ];
      description = "Further arguments to nanohub.";
    };

    pushCertificate = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            certFile = lib.mkOption {
              type = fileType;
              description = "The MDM push certificate from Apple (identity.apple.com/pushcert), PEM.";
            };
            keyFile = lib.mkOption {
              type = fileType;
              description = "Its private key, PEM, unencrypted.";
            };
          };
        }
      );
      default = null;
      description = "The APNs push certificate, uploaded to nanohub on every start.";
    };

    declarations = lib.mkOption {
      type = lib.types.attrsOf declarationType;
      default = { };
      example = lib.literalExpression ''
        {
          "com.example.passcode" = {
            type = "com.apple.configuration.passcode.settings";
            payload = { RequirePasscode = true; MinimumLength = 6; };
          };
        }
      '';
      description = ''
        Declarations by Identifier. When any of declarations, sets or
        enrollmentSets is set, ones nanohub has that are not here are deleted.
      '';
    };

    sets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = {
        default = [ "com.example.passcode" ];
      };
      description = "Sets of declarations (Identifiers), by name. Undeclared sets are emptied.";
    };

    enrollmentSets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = {
        "00008110-000A1B2C3D4E5F6A" = [ "default" ];
      };
      description = ''
        The sets each enrollment is in, by enrollment ID (a device's UDID).
        An enrollment not listed is left as it is.
      '';
    };

    enrollmentProfile = {
      enable = lib.mkEnableOption "building the enrollment profile, at enrollmentProfile.path";

      path = lib.mkOption {
        type = lib.types.str;
        default = "/run/nanohub-enrollment/enroll.mobileconfig";
        readOnly = true;
        description = "Where the profile is, for a web server to offer. Readable by enrollmentProfile.group.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = cfg.group;
        defaultText = lib.literalExpression "config.services.nanohub.group";
        example = "nginx";
        description = "Group that can read the profile (it holds the SCEP challenge).";
      };

      identifier = lib.mkOption {
        type = lib.types.str;
        example = "com.example.mdm";
        description = "Reverse-DNS identifier of the profile; its payloads' are under it.";
      };

      displayName = lib.mkOption {
        type = lib.types.str;
        default = profile.organization;
        defaultText = lib.literalExpression "config.services.nanohub.enrollmentProfile.organization";
        description = "The profile's name, as Settings shows it.";
      };

      organization = lib.mkOption {
        type = lib.types.str;
        example = "Example Inc.";
        description = "Who manages the device, as Settings shows it.";
      };

      description = lib.mkOption {
        type = lib.types.str;
        default = "Lets ${profile.organization} manage this device.";
        defaultText = lib.literalExpression ''"Lets ''${organization} manage this device."'';
        description = "The profile's description.";
      };

      serverURL = lib.mkOption {
        type = lib.types.str;
        example = "https://mdm.example.com/mdm";
        description = "nanohub's /mdm, as devices reach it.";
      };

      checkInURL = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "nanohub's /checkin, when run with -checkin.";
      };

      accessRights = lib.mkOption {
        type = lib.types.ints.between 1 8191;
        default = 8191;
        description = "What the server may do (bitmask); everything by default.";
      };

      scep = {
        url = lib.mkOption {
          type = lib.types.str;
          example = "https://mdm.example.com/scep";
          description = "The SCEP server devices get their identity from.";
        };
        challengeFile = lib.mkOption {
          type = lib.types.nullOr fileType;
          default = null;
          description = "File with the SCEP challenge password.";
        };
        subject = lib.mkOption {
          type = lib.types.listOf (lib.types.listOf lib.types.str);
          default = [
            [
              "O"
              profile.organization
            ]
            [
              "CN"
              "MDM device identity"
            ]
          ];
          defaultText = lib.literalExpression ''[ [ "O" organization ] [ "CN" "MDM device identity" ] ]'';
          description = "Subject of the device's certificate, as [ type value ] pairs.";
        };
        keySize = lib.mkOption {
          type = lib.types.enum [
            1024
            2048
            4096
          ];
          default = 2048;
          description = "RSA key size.";
        };
      };

      signing = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              certFile = lib.mkOption {
                type = fileType;
                description = "Certificate to sign with, PEM: a TLS certificate does.";
              };
              keyFile = lib.mkOption {
                type = fileType;
                description = "Its private key, PEM.";
              };
              chainFile = lib.mkOption {
                type = lib.types.nullOr fileType;
                default = null;
                description = "Intermediates to include, PEM.";
              };
            };
          }
        );
        default = null;
        description = "Sign the profile, so Settings shows it as verified. Unsigned when null.";
      };

      extraPayloads = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        default = [ ];
        description = "More payloads for the profile, installed along with enrollment.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = needsSync -> cfg.apiKeyFile != null;
        message = "services.nanohub: pushCertificate and declarative management need apiKeyFile.";
      }
      {
        assertion = profile.enable -> cfg.pushCertificate != null;
        message = "services.nanohub.enrollmentProfile: the profile's topic comes from pushCertificate.";
      }
    ];

    users.users = lib.mkIf (cfg.user == "nanohub") {
      nanohub = {
        isSystemUser = true;
        inherit (cfg) group;
      };
    };
    users.groups = lib.mkIf (cfg.group == "nanohub") { nanohub = { }; };

    systemd.services.nanohub = {
      description = "NanoHUB MDM server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "nanohub";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/nanohub";
        LoadCredential =
          lib.optional (cfg.caFile != null) "ca.pem:${cfg.caFile}"
          ++ lib.optional (cfg.apiKeyFile != null) "api-key:${cfg.apiKeyFile}";
        ExecStart = pkgs.writeShellScript "nanohub-start" ''
          set -eu
          ${lib.optionalString (cfg.apiKeyFile != null) ''
            NANOHUB_API_KEY=$(cat "$CREDENTIALS_DIRECTORY/api-key")
            export NANOHUB_API_KEY
          ''}
          exec ${
            lib.escapeShellArgs (
              [
                (lib.getExe cfg.package)
                "-listen"
                "${cfg.listenAddress}:${toString cfg.port}"
                "-storage"
                cfg.storage.backend
                "-storage-dsn"
                cfg.storage.dsn
              ]
              ++ cfg.extraArgs
            )
          } ${lib.optionalString (cfg.caFile != null) ''-ca "$CREDENTIALS_DIRECTORY/ca.pem"''}
        '';
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
    };

    systemd.services.nanohub-sync = lib.mkIf needsSync {
      description = "Make NanoHUB's push certificate and declarations match the configuration";
      wantedBy = [ "multi-user.target" ];
      requires = [ "nanohub.service" ];
      after = [ "nanohub.service" ];
      partOf = [ "nanohub.service" ];
      restartTriggers = [ sync ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        LoadCredential = [
          "api-key:${cfg.apiKeyFile}"
        ]
        ++ lib.optionals (cfg.pushCertificate != null) [
          "push.crt:${cfg.pushCertificate.certFile}"
          "push.key:${cfg.pushCertificate.keyFile}"
        ];
        ExecStart = lib.getExe sync;
      };
    };

    systemd.services.nanohub-enrollment-profile = lib.mkIf profile.enable {
      description = "Build NanoHUB's enrollment profile";
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ buildProfile ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = profile.group;
        RuntimeDirectory = "nanohub-enrollment";
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = true;
        LoadCredential = [
          "push.crt:${cfg.pushCertificate.certFile}"
        ]
        ++ lib.optional (profile.scep.challengeFile != null) "challenge:${profile.scep.challengeFile}"
        ++ lib.optionals (profile.signing != null) (
          [
            "sign.crt:${profile.signing.certFile}"
            "sign.key:${profile.signing.keyFile}"
          ]
          ++ lib.optional (profile.signing.chainFile != null) "sign.chain:${profile.signing.chainFile}"
        );
        ExecStart = lib.getExe buildProfile;
      };
    };
  };
}
