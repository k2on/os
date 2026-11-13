# The household's Apple devices, managed from here, at
# apple.devices.<mainDomain>: nanohub (services.nanohub,
# ./_nanohub-module.nix) is the MDM server and scepserver (services.scep,
# ./_scep-module.nix) issues each device the identity certificate it signs
# its check-ins with. Those two modules are generic; this file is what ark
# makes of them: its secrets, its names, its nginx. Public (lib/public.nix):
# a phone reaches its MDM server from wherever it is, woken by Apple's push
# service.
#
# Everything a device gets is declared under ark.devices.apple:
# declarations (Apple's declarative device management), the sets they are
# grouped in, and which device (by UDID) is in which. nanohub-sync makes
# nanohub's match on every start and every change.
#
# Enrolling: on the tailnet, open https://devices.<mainDomain>/enroll in
# Safari, then Settings -> Profile Downloaded -> Install. The profile asks
# scepserver for the device's certificate and points the device at
# nanohub; it says ark.devices.apple.organization manages the device. Then
# the device's UDID (`journalctl -u nanohub`) goes in
# ark.devices.apple.devices.
#
# The push certificate is the one thing that cannot be generated here: an
# MDM push certificate from Apple (identity.apple.com/pushcert), whose
# request a vendor has to sign (mdmcert.download does this for anyone).
# It lasts a year; renew it with the same Apple ID or every device has to
# enroll again. Until it is in sops (`ark sops devices-apple-push.yaml`:
# devices-apple_push_cert and devices-apple_push_key, PEM) ark builds
# without it and no enrollment profile is offered.
#
# nanohub's API (/api/v1/..., user nanohub, devices-apple_api_key) is on
# the tailnet name only: devices.<mainDomain>.
#
# Automated Device Enrollment (services.nanodep, ./_nanodep-module.nix):
# a device in Apple Business Manager, assigned to the MDM server there
# made for this, enrolls itself in Setup Assistant, supervised and for
# good. Setting it up, once:
#   1. In ABM, Preferences -> Your MDM Servers -> Add: upload the
#      certificate of devices-apple_dep_pki (`ark sops decrypt --extract
#      '["devices-apple_dep_pki"]' secrets/vars/devices-apple.yaml |
#      openssl x509 > abm.pem`), then download the server's token.
#   2. Put the token in sops (`ark sops devices-apple-dep.yaml`:
#      devices-apple_dep_token) and deploy: nanodep-sync uploads it, defines
#      the ADE profile (ark.devices.apple.ade) and assigns it to the serial
#      numbers in ark.devices.apple.devices; depsyncer gives it to any device
#      newly assigned to the server as well.
#   3. Make that server the default for iPhone/iPad in ABM, and add the
#      device (Apple Configurator for iPhone, for one bought retail).
# In Setup Assistant the device POSTs its signed MachineInfo to
# apple.devices.<mainDomain>/enroll, where apple-enroll (./enroll) hands
# back the enrollment profile, to declared serial numbers only. The token
# lasts a year, like the push certificate.
{ lib, config, ... }:
let
  ark = config.ark;
  apple = config.ark.devices.apple;
  domain = "apple.devices.${ark.mainDomain}";
  # Tailnet only: the enrollment profile and the API.
  adminDomain = "devices.${ark.mainDomain}";
  # Reverse-DNS prefix for the profile's and declarations' identifiers.
  prefix =
    lib.concatStringsSep "." (lib.reverseList (lib.splitString "." ark.mainDomain)) + ".devices";
in
{
  options.ark.devices.apple = {
    organization = lib.mkOption {
      type = lib.types.str;
      default = ark.oidc.name;
      defaultText = lib.literalExpression "config.ark.oidc.name";
      example = "ACME";
      description = "Who manages the devices, as their Settings show it. The identity provider's name by default.";
    };

    declarations = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      description = "services.nanohub.declarations.";
    };

    sets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      description = "services.nanohub.sets. Every device is in `default`.";
    };

    devices = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            udid = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The device's UDID: its enrollment ID, logged by nanohub (`id=`) when it enrolls. Its sets apply once it is here.";
            };
            serial = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The device's serial number: with one, Automated Device Enrollment gives it the ADE profile and the enrollment profile.";
            };
            sets = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Sets the device is in, besides `default`.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''{ max-iphone = { udid = "00008110-000A1B2C3D4E5F6A"; serial = "KN2QHVKC9J"; }; }'';
      description = "Enrolled devices, by any name.";
    };

    ade = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        skip_setup_items = [
          "Android"
          "Privacy"
        ];
        support_phone_number = "+1 555 0100";
      };
      description = ''
        The ADE profile (services.nanodep.names.abm.profile), over the
        defaults here: supervised, not removable, enrolling at
        apple.devices.<mainDomain>/enroll.
      '';
    };
  };

  config.ark.devices.apple = {
    # Every device reports what it is and runs.
    declarations."${prefix}.status" = {
      type = "com.apple.configuration.management.status-subscriptions";
      payload.StatusItems = map (name: { Name = name; }) [
        "device.identifier.serial-number"
        "device.identifier.udid"
        "device.model.family"
        "device.model.identifier"
        "device.operating-system.version"
        "device.operating-system.build-version"
      ];
    };
    sets.default = [ "${prefix}.status" ];
  };

  config.ark.public."apple.devices" = 443;

  config.perSystem =
    { pkgs, ... }:
    let
      apple-enroll = pkgs.callPackage ../../../_rust.nix { pname = "apple-enroll"; };
    in
    {
      packages = { inherit apple-enroll; };
      checks.apple-enroll = pkgs.callPackage ./_enroll-check.nix { inherit apple-enroll; };
    };

  config.ark.services.devices-apple = {
    inherit domain;
    # devices.<mainDomain> on the tailnet's DNS; its vhost is below.
    aliases = [ "devices" ];

    secrets = {
      devices-apple_api_key = {
        file = "devices-apple";
        generate = true;
      };
      devices-apple_scep_challenge = {
        file = "devices-apple";
        generate = true;
      };
      # scepserver's CA, which nanohub checks device identities against:
      # certificate and key, one PEM. Ten years.
      devices-apple_scep_ca = {
        file = "devices-apple";
        generate = ''
          key=$(mktemp)
          openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=Device CA" \
            -addext basicConstraints=critical,CA:TRUE \
            -addext keyUsage=critical,keyCertSign,cRLSign \
            -keyout "$key" 2>/dev/null
          cat "$key"
          rm "$key"
        '';
      };
      # From Apple, by hand (see the top of this file).
      devices-apple_push_cert = {
        file = "devices-apple-push";
        optional = true;
        restartUnits = [
          "nanohub-sync.service"
          "nanohub-enrollment-profile.service"
        ];
      };
      devices-apple_push_key = {
        file = "devices-apple-push";
        optional = true;
        restartUnits = [ "nanohub-sync.service" ];
      };

      # Automated Device Enrollment (Apple Business Manager). depserver's
      # API key, and the key pair ABM encrypts the MDM server's token to:
      # certificate and key, one PEM; the certificate is what ABM is given.
      devices-apple_dep_api_key = {
        file = "devices-apple";
        generate = true;
      };
      devices-apple_dep_pki = {
        file = "devices-apple";
        generate = ''
          key=$(mktemp)
          openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=depserver" \
            -keyout "$key" 2>/dev/null
          cat "$key"
          rm "$key"
        '';
      };
      # The token ABM gives back for that certificate (the _smime.p7m), by
      # hand: `ark sops devices-apple-dep.yaml`. Until it is there, no ADE.
      devices-apple_dep_token = {
        file = "devices-apple-dep";
        optional = true;
        restartUnits = [ "nanodep-sync.service" ];
      };
    };

    backup = {
      paths = [
        "/var/lib/nanohub"
        "/var/lib/scep"
        "/var/lib/nanodep"
      ];
      stop = [
        "nanohub.service"
        "scep.service"
        "depserver.service"
        "depsyncer.service"
      ];
    };

    nixos =
      {
        service,
        config,
        pkgs,
        ...
      }:
      let
        secrets = config.sops.secrets;
        hasPush = secrets ? devices-apple_push_cert;
        acme = config.security.acme.certs.${ark.mainDomain}.directory;
        hasToken = secrets ? devices-apple_dep_token;
        # nanohub is service.port; the rest beside it.
        scepPort = service.port + 1;
        enrollPort = service.port + 2;
        depPort = service.port + 3;
        serials = lib.filter (s: s != null) (lib.mapAttrsToList (_: d: d.serial) apple.devices);
      in
      {
        imports = [
          ./_nanohub-module.nix
          ./_scep-module.nix
          ./_nanodep-module.nix
        ];

        # apple.devices.<mainDomain> is a level below the wildcard.
        security.acme.certs.${ark.mainDomain}.extraDomainNames = [ domain ];

        services.scep = {
          enable = true;
          package = pkgs.callPackage ./_scep.nix { };
          port = scepPort;
          caCertFile = secrets.devices-apple_scep_ca.path;
          caKeyFile = secrets.devices-apple_scep_ca.path;
          challengePasswordFile = secrets.devices-apple_scep_challenge.path;
          # As long as the CA, so a device never has to enroll again.
          certificateValidity = 3650;
        };

        services.nanohub = {
          enable = true;
          package = pkgs.callPackage ./_nanohub.nix { };
          inherit (service) port;
          caFile = secrets.devices-apple_scep_ca.path;
          apiKeyFile = secrets.devices-apple_api_key.path;
          pushCertificate = lib.mkIf hasPush {
            certFile = secrets.devices-apple_push_cert.path;
            keyFile = secrets.devices-apple_push_key.path;
          };

          inherit (apple) declarations sets;
          enrollmentSets = lib.listToAttrs (
            lib.mapAttrsToList (_: d: lib.nameValuePair d.udid (lib.unique ([ "default" ] ++ d.sets))) (
              lib.filterAttrs (_: d: d.udid != null) apple.devices
            )
          );

          enrollmentProfile = {
            enable = hasPush;
            group = "nginx";
            identifier = prefix;
            inherit (apple) organization;
            serverURL = "https://${domain}/mdm";
            scep = {
              url = "https://${domain}/scep";
              challengeFile = secrets.devices-apple_scep_challenge.path;
            };
            # ark's certificate: Settings shows the profile as verified.
            signing = {
              certFile = "${acme}/cert.pem";
              keyFile = "${acme}/key.pem";
              chainFile = "${acme}/chain.pem";
            };
          };
        };

        systemd.services.nanohub-enrollment-profile = lib.mkIf hasPush {
          wants = [ "acme-finished-${ark.mainDomain}.target" ];
          after = [ "acme-finished-${ark.mainDomain}.target" ];
        };

        # One MDM server in ABM, "abm". Its ADE profile only once there is
        # a token to define it with and an enrollment profile to hand out.
        services.nanodep = {
          enable = true;
          package = pkgs.callPackage ./_nanodep.nix { };
          port = depPort;
          apiKeyFile = secrets.devices-apple_dep_api_key.path;
          names.abm = {
            tokenPKI = {
              certFile = secrets.devices-apple_dep_pki.path;
              keyFile = secrets.devices-apple_dep_pki.path;
            };
            tokenFile = lib.mkIf hasToken secrets.devices-apple_dep_token.path;
            profile = lib.mkIf (hasToken && hasPush) (
              {
                profile_name = apple.organization;
                url = "https://${domain}/enroll";
                is_supervised = true;
                is_mandatory = true;
                is_mdm_removable = false;
                await_device_configured = false;
                allow_pairing = true;
                department = apple.organization;
              }
              // apple.ade
            );
            devices = serials;
          };
        };

        # The enrollment URL of the ADE profile: the enrollment profile, to
        # declared serial numbers only (./enroll).
        systemd.services.apple-enroll = lib.mkIf hasPush {
          description = "Hand the enrollment profile to Apple devices in Setup Assistant";
          wantedBy = [ "multi-user.target" ];
          after = [ "nanohub-enrollment-profile.service" ];
          path = [ pkgs.openssl ];
          serviceConfig = {
            ExecStart = lib.escapeShellArgs [
              (lib.getExe (pkgs.callPackage ../../../_rust.nix { pname = "apple-enroll"; }))
              "127.0.0.1:${toString enrollPort}"
              config.services.nanohub.enrollmentProfile.path
              (pkgs.writeText "apple-enroll-serials" (lib.concatLines serials))
            ];
            Restart = "on-failure";
            DynamicUser = true;
            # The profile is readable by its group (enrollmentProfile.group).
            SupplementaryGroups = [ config.services.nanohub.enrollmentProfile.group ];
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            NoNewPrivileges = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
            ];
          };
        };

        services.nginx.virtualHosts = {
          # Public: what devices talk to. "/" is nanohub (lib/services.nix).
          ${domain}.locations = {
            "/scep".proxyPass = "http://127.0.0.1:${toString scepPort}";
            "/api/".return = "404";
            # Setup Assistant, for ADE: apple-enroll decides who gets it.
            "= /enroll" =
              if hasPush then { proxyPass = "http://127.0.0.1:${toString enrollPort}"; } else { return = "404"; };
          };

          # Tailnet: the profile and the API. The vps forwards only
          # apple.devices.* (by SNI), so a request that came through it
          # cannot be for this name.
          ${adminDomain} = {
            useACMEHost = ark.mainDomain;
            forceSSL = true;
            extraConfig = ''
              if ($ssl_server_name != "${adminDomain}") { return 421; }
            '';
            locations = {
              "= /enroll".extraConfig = ''
                default_type application/x-apple-aspen-config;
                add_header Content-Disposition 'attachment; filename="enroll.mobileconfig"';
                alias ${config.services.nanohub.enrollmentProfile.path};
              '';
              "/api/".proxyPass = "http://127.0.0.1:${toString service.port}";
            };
          };
        };
      };
  };
}
