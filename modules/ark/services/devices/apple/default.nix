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
              type = lib.types.str;
              description = "The device's UDID: its enrollment ID, logged by nanohub when it enrolls.";
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
      example = lib.literalExpression ''{ max-iphone.udid = "00008110-000A1B2C3D4E5F6A"; }'';
      description = "Enrolled devices, by any name.";
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
    };

    backup = {
      paths = [
        "/var/lib/nanohub"
        "/var/lib/scep"
      ];
      stop = [
        "nanohub.service"
        "scep.service"
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
        scepPort = service.port + 1;
      in
      {
        imports = [
          ./_nanohub-module.nix
          ./_scep-module.nix
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
            lib.mapAttrsToList (
              _: d: lib.nameValuePair d.udid (lib.unique ([ "default" ] ++ d.sets))
            ) apple.devices
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

        services.nginx.virtualHosts = {
          # Public: what devices talk to. "/" is nanohub (lib/services.nix).
          ${domain}.locations = {
            "/scep".proxyPass = "http://127.0.0.1:${toString scepPort}";
            "/api/".return = "404";
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
