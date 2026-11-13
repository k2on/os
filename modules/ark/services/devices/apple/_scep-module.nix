# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# services.scep: micromdm's SCEP server (./_scep.nix), a certificate
# authority devices ask for a certificate over SCEP — for Apple MDM, the
# identity each device signs its check-ins with. Written with nothing of
# ark in it, to go to nixpkgs one day (with pkgs.scep there).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.scep;
in
{
  options.services.scep = {
    enable = lib.mkEnableOption "the micromdm SCEP server";

    package = lib.mkPackageOption pkgs "scep" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "scep";
      description = "User the server runs as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "scep";
      description = "Group the server runs as.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address to listen on. SCEP is served at /scep.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port to listen on.";
    };

    caCertFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        PEM file with the CA's certificate. May be the same file as
        caKeyFile; only the certificate is taken from it.
      '';
    };

    caKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        PEM file with the CA's private key (RSA), unencrypted. Read through
        systemd credentials, so it may be readable by root alone.
      '';
    };

    challengePasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File with the challenge password a request must carry. null accepts any request.";
    };

    certificateValidity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 365;
      description = "Days the certificates it issues are valid for.";
    };

    allowRenewal = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 14;
      description = "Days before expiry a certificate may be renewed; 0 for any time.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Further arguments to scepserver.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.mkIf (cfg.user == "scep") {
      scep = {
        isSystemUser = true;
        inherit (cfg) group;
      };
    };
    users.groups = lib.mkIf (cfg.group == "scep") { scep = { }; };

    systemd.services.scep = {
      description = "SCEP server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        # The depot: the CA, then every certificate it issues.
        StateDirectory = "scep";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/scep";
        LoadCredential = [
          "ca.crt:${cfg.caCertFile}"
          "ca.key:${cfg.caKeyFile}"
        ]
        ++ lib.optional (cfg.challengePasswordFile != null) "challenge:${cfg.challengePasswordFile}";
        ExecStart = pkgs.writeShellScript "scep-start" ''
          set -eu
          umask 077
          # scepserver reads the first PEM block of each: the certificate
          # and the key alone, whatever else the files hold.
          ${lib.getExe pkgs.openssl} x509 -in "$CREDENTIALS_DIRECTORY/ca.crt" -out ca.pem
          ${lib.getExe pkgs.openssl} pkey -in "$CREDENTIALS_DIRECTORY/ca.key" -out ca.key
          ${lib.optionalString (cfg.challengePasswordFile != null) ''
            SCEP_CHALLENGE_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/challenge")
            export SCEP_CHALLENGE_PASSWORD
          ''}
          exec ${
            lib.escapeShellArgs (
              [
                (lib.getExe cfg.package)
                "-http-addr"
                "${cfg.listenAddress}:${toString cfg.port}"
                "-depot"
                "/var/lib/scep"
                "-crtvalid"
                (toString cfg.certificateValidity)
                "-allowrenew"
                (toString cfg.allowRenewal)
              ]
              ++ cfg.extraArgs
            )
          }
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
  };
}
