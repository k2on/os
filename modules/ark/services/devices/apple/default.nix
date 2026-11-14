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
#
# Apps (ark.devices.apple.apps; Tailscale, pointed at headscale): App Store
# apps every device with a serial number gets, with no Apple ID. In ABM,
# Apps and Books: "buy" licenses for the app (free apps cost nothing, but
# Payments and Billing needs a payment method, "None" will do), then
# download the location's content token into sops (`ark sops
# devices-apple-vpp.yaml`: devices-apple_vpp_token). apple-vpp-sync
# (./_vpp-module.nix) then gives each device a license, and nanohub's
# declarations install the app, managed, with its config: a plist at
# apple.devices.<mainDomain>/assets/<sha256>.plist (dataAssets). Installed
# this way, as required, an app can't be deleted from the device ("required
# by your organization").
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
  # Each device with its name, as the apps' config functions see it.
  deviceList = lib.mapAttrsToList (name: d: d // { inherit name; }) apple.devices;

  # People whose enrolled devices get their own things (their mail account):
  # a set each, person-<name>, that their devices are in besides default.
  owners = lib.unique (
    map (d: d.owner) (lib.filter (d: d.owner != null && d.udid != null) deviceList)
  );
  personSet = p: "person-${p}";
  # Their mailbox (services/mail): IMAP and SMTP over TLS, user name the
  # person's username, password their mail_password_<person>.
  hasMail = ark.services ? mail;
  mailHost = "mail.${ark.mainDomain}";
  mailPassword = p: "mail_password_${p}";
  # Their calendars (services/radicale), under their own login: shared
  # groups' calendars are among them (ark.radicale.sharedGroups).
  hasCalendar = ark.services ? radicale;
  calendarHost = ark.serviceDomain "radicale" ark.services.radicale;
  calendarPassword = name: "radicale_password_${name}";
  # Radicale runs on adam too and declares those secrets itself, so this
  # service's copies have their own names (the same sops key).
  calendarSecret = name: "${calendarPassword name}_devices";
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
            owner = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum (lib.attrNames ark.persons));
              default = null;
              description = "Whose device it is (ark.persons): apps that sign in, like Tailscale, sign in as them.";
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

    wallpaper = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            color = lib.mkOption {
              type = lib.types.str;
              example = "black";
              description = "A solid colour, as ImageMagick names it (black, #1e1e2e, ...).";
            };
            where = lib.mkOption {
              type = lib.types.enum [
                1
                2
                3
              ];
              default = 3;
              description = "1 the Lock Screen, 2 the Home Screen, 3 both.";
            };
          };
        }
      );
      default = null;
      description = "Every enrolled device's wallpaper (services.nanohub.wallpaper).";
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf (lib.types.attrsOf lib.types.anything));
      default = { };
      example = lib.literalExpression ''
        {
          restrictions = [
            {
              PayloadType = "com.apple.applicationaccess";
              blockedAppBundleIDs = [ "com.apple.tips" ];
            }
          ];
        }
      '';
      description = ''
        Profiles every device gets, by name, as lists of payloads (without
        PayloadUUID/PayloadVersion/PayloadIdentifier, which are added): for
        settings with no declaration of their own, like restrictions. Public.
      '';
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                false: off every device. Its declarations are deleted, so the
                device removes the app and the profile that came with it.
              '';
            };
            storeId = lib.mkOption {
              type = lib.types.str;
              example = "1470499037";
              description = "The app's App Store ID: the number in its apps.apple.com URL.";
            };
            config = lib.mkOption {
              type = lib.types.either (lib.types.attrsOf lib.types.anything) (
                lib.types.functionTo (lib.types.attrsOf lib.types.anything)
              );
              default = { };
              description = ''
                Its managed app configuration (what the app's vendor documents
                for MDM). Either the same for every device, public; or a
                function of the device ({ name, owner, udid, serial, ... }),
                each device's own, given only to it, with @placeholders@ for
                `secrets`.
              '';
            };
            secrets = lib.mkOption {
              type = lib.types.functionTo (lib.types.attrsOf lib.types.str);
              default = _: { };
              description = "Per device: the sops secret whose value replaces each @placeholder@ in its config.";
            };
            payloads = lib.mkOption {
              type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
              default = [ ];
              description = ''
                Profile payloads that go with the app (its VPN, say), without
                PayloadUUID/PayloadVersion/PayloadIdentifier, which are added:
                one profile per app, the same for every device. Public.
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        App Store apps every device with a serial number gets: a device
        license from Apps and Books (licenses bought in ABM for the
        content token's location), installed and kept managed, with its
        config. Only once the content token is in sops.
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
        # Its managed apps as they change: installing, managed, failed.
        "app.managed.list"
      ];
    };
    sets.default = [ "${prefix}.status" ];

    # The tailnet, joined as the device's owner with their pre-auth key
    # (services/headscale), named after the device. tailscale.com/kb/1315/mdm-keys
    apps.tailscale = {
      enable = true;
      storeId = "1470499037";
      config =
        device:
        {
          LoginURL = "https://${ark.serviceDomain "headscale" ark.services.headscale}";
          ManagedByOrganizationName = apple.organization;
          Hostname = device.name;
          # Always on: no disconnecting or quitting in the app, and no
          # changing its On Demand (the profile below holds it on).
          "AlwaysOn.Enabled" = true;
          VPNOnDemandSettings = "hide";
        }
        // lib.optionalAttrs (device.owner != null) { AuthKey = "@authkey@"; };
      secrets =
        device:
        lib.optionalAttrs (device.owner != null) { authkey = "headscale_preauth_key_${device.owner}"; };
      # Its VPN, there before the app first opens (so no "add VPN
      # configurations" prompt) and connected by iOS whenever there is a
      # network (On Demand). tailscale.com/docs/integrations/mdm/ios
      payloads = [
        {
          PayloadType = "com.apple.vpn.managed";
          PayloadDisplayName = "Tailscale";
          UserDefinedName = "Tailscale";
          VPNType = "VPN";
          VPNSubType = "io.tailscale.ipn.ios";
          VPN = {
            RemoteAddress = "Tailscale Mesh";
            AuthenticationMethod = "Password";
            ProviderBundleIdentifier = "io.tailscale.ipn.ios.network-extension";
            OnDemandEnabled = 1;
            OnDemandRules = [ { Action = "Connect"; } ];
            # Settings' Connect On Demand toggle, greyed out: no turning it
            # off there either.
            OnDemandUserOverrideDisabled = 1;
          };
        }
      ];
    };
  };

  config.ark.public."apple.devices" = 443;

  config.perSystem =
    { pkgs, ... }:
    let
      apple-enroll = pkgs.callPackage ../../../_rust.nix { pname = "apple-enroll"; };
      apple-devices-metrics = pkgs.callPackage ../../../_rust.nix { pname = "apple-devices-metrics"; };
    in
    {
      packages = { inherit apple-enroll apple-devices-metrics; };
      checks.apple-enroll = pkgs.callPackage ./_enroll-check.nix { inherit apple-enroll; };
      checks.apple-devices-metrics = pkgs.callPackage ./_metrics-check.nix {
        inherit apple-devices-metrics;
      };
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
      # Apps and Books' content token for the location the app licenses
      # are in (Preferences -> Payments and Billing -> Content Tokens), by
      # hand: `ark sops devices-apple-vpp.yaml`. Until it is there, no apps.
      devices-apple_vpp_token = {
        file = "devices-apple-vpp";
        optional = true;
        restartUnits = [ "apple-vpp-sync.service" ];
      };
    }
    # Whatever the apps' configs take from sops (an owner's tailnet key).
    //
      lib.genAttrs
        (lib.unique (
          lib.concatMap (app: lib.concatMap (d: lib.attrValues (app.secrets d)) deviceList) (
            lib.attrValues apple.apps
          )
        ))
        (_: {
          restartUnits = [ "nanohub-assets.service" ];
        })
    # Device owners' mail passwords, for their mail accounts (the mail
    # host's secrets, shared).
    // lib.optionalAttrs hasMail (
      lib.genAttrs' owners (
        p:
        lib.nameValuePair (mailPassword p) {
          restartUnits = [ "nanohub-assets.service" ];
        }
      )
    )
    # Their calendar passwords (services/radicale's).
    // lib.optionalAttrs hasCalendar (
      lib.genAttrs' owners (
        name:
        lib.nameValuePair (calendarSecret name) {
          key = calendarPassword name;
          restartUnits = [ "nanohub-assets.service" ];
        }
      )
    );

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
        assetPort = service.port + 4;
        metricsPort = service.port + 5;
        serials = lib.filter (s: s != null) (lib.mapAttrsToList (_: d: d.serial) apple.devices);

        # Apps: each a managed-app declaration and its config as a data
        # asset, in the default set, once licenses can be assigned.
        hasVpp = secrets ? devices-apple_vpp_token;
        appId = name: "${prefix}.app.${name}";
        configId = name: "${appId name}.config";
        profileId = name: "${appId name}.profile";
        apps = lib.optionalAttrs hasVpp (lib.filterAttrs (_: app: app.enable) apple.apps);

        # A stable UUID per name, so a new profile replaces the old one.
        uuid =
          name:
          let
            h = builtins.hashString "sha256" "${prefix}.${name}";
            s = start: len: lib.substring start len h;
          in
          lib.toUpper "${s 0 8}-${s 8 4}-4${s 13 3}-8${s 17 3}-${s 20 12}";
        # Payloads as one profile, under identifier id.
        mkProfile = id: name: payloads: {
          content = toPlist {
            PayloadType = "Configuration";
            PayloadVersion = 1;
            PayloadIdentifier = id;
            PayloadUUID = uuid id;
            PayloadDisplayName = "${apple.organization}: ${name}";
            PayloadOrganization = apple.organization;
            PayloadScope = "System";
            PayloadContent = lib.imap0 (
              i: p:
              {
                PayloadVersion = 1;
                PayloadIdentifier = "${id}.${toString i}";
                PayloadUUID = uuid "${id}.${toString i}";
              }
              // p
            ) payloads;
          };
        };
        # Each app's payloads as one profile, and ark.devices.apple.profiles.
        appProfiles = lib.mapAttrs' (
          name: app: lib.nameValuePair (profileId name) (mkProfile (profileId name) name app.payloads)
        ) (lib.filterAttrs (_: app: app.payloads != [ ]) apps);
        deviceProfiles = lib.mapAttrs' (
          name: payloads:
          lib.nameValuePair "${prefix}.profile.${name}" (mkProfile "${prefix}.profile.${name}" name payloads)
        ) apple.profiles;
        allProfiles = appProfiles // deviceProfiles;
        appDeclarations = lib.mapAttrs' (
          name: app:
          lib.nameValuePair (appId name) {
            type = "com.apple.configuration.app.managed";
            payload = {
              AppStoreID = app.storeId;
              InstallBehavior = {
                Install = "Required";
                License.Assignment = "Device";
              };
            }
            // lib.optionalAttrs (app.config != { }) { LegacyAppConfigAssetReference = configId name; };
          }
        ) apps;
        # Each owner's identity, mail account and calendar account. Passwords
        # are private assets, given only to the devices they're for.
        personId = p: "${prefix}.person.${p}";
        devicesOf = p: lib.filter (d: d.owner == p && d.udid != null) deviceList;
        # A user name and the password in sops secret, for these devices.
        credential = user: secret: devices: {
          type = "com.apple.asset.credential.userpassword";
          contentType = "application/json";
          extension = "json";
          escape = "json";
          enrollments = lib.listToAttrs (
            map (
              d:
              lib.nameValuePair d.udid {
                content = builtins.toJSON {
                  UserName = user;
                  Password = "@password@";
                };
                substitutions.password = config.sops.secrets.${secret}.path;
              }
            ) devices
          );
        };
        calendarAccount = name: credentialId: {
          type = "com.apple.configuration.account.caldav";
          payload = {
            VisibleName = name;
            HostName = calendarHost;
            Port = 443;
            AuthenticationCredentialsAssetReference = credentialId;
          };
        };

        # Each person's: declarations and assets by identifier.
        personThings =
          p:
          let
            person = ark.persons.${p};
          in
          {
            declarations =
              lib.optionalAttrs hasMail {
                "${personId p}.identity" = {
                  type = "com.apple.asset.useridentity";
                  payload = {
                    FullName = person.displayName;
                    EmailAddress = person.mail;
                  };
                };
                "${personId p}.mail" = {
                  type = "com.apple.configuration.account.mail";
                  payload =
                    let
                      server = port: {
                        HostName = mailHost;
                        Port = port;
                        AuthenticationMethod = "Password";
                        AuthenticationCredentialsAssetReference = "${personId p}.mail.credential";
                      };
                    in
                    {
                      VisibleName = person.mail;
                      UserIdentityAssetReference = "${personId p}.identity";
                      IncomingServer = server 993 // {
                        ServerType = "IMAP";
                      };
                      OutgoingServer = server 465;
                    };
                };
              }
              // lib.optionalAttrs hasCalendar {
                "${personId p}.calendar" = calendarAccount person.displayName "${personId p}.calendar.credential";
              };
            assets =
              lib.optionalAttrs hasMail {
                "${personId p}.mail.credential" = credential p (mailPassword p) (devicesOf p);
              }
              // lib.optionalAttrs hasCalendar {
                "${personId p}.calendar.credential" = credential p (calendarSecret p) (devicesOf p);
              };
          };
        people = lib.genAttrs owners personThings;
        personDeclarations = lib.concatMapAttrs (_: t: t.declarations) people;
        personAssets = lib.concatMapAttrs (_: t: t.assets) people;
        personSets = lib.mapAttrs' (
          p: t: lib.nameValuePair (personSet p) (lib.attrNames t.declarations ++ lib.attrNames t.assets)
        ) people;

        allDeclarations = apple.declarations // appDeclarations // personDeclarations;
        sets =
          apple.sets
          // personSets
          // {
            default =
              (apple.sets.default or [ ])
              ++ lib.attrNames appDeclarations
              ++ lib.attrNames appConfigs
              ++ lib.attrNames allProfiles;
          };
        # A configuration does nothing until an activation names it
        # (Info.NotReferencedByActivation): one per set, naming every
        # configuration in it. Assets are not named; what refers to them is.
        activationId = set: "${prefix}.activation.${set}";
        activations = lib.mapAttrs' (
          set: ids:
          lib.nameValuePair (activationId set) {
            type = "com.apple.activation.simple";
            # Profiles are declared by nanohub (com.apple.configuration.legacy).
            payload.StandardConfigurations = lib.filter (
              id:
              allProfiles ? ${id}
              || allDeclarations ? ${id} && lib.hasPrefix "com.apple.configuration." allDeclarations.${id}.type
            ) ids;
          }
        ) sets;

        toPlist = lib.generators.toPlist { escape = true; };
        # A config per device goes to enrolled devices (with a UDID) only.
        appConfigs = lib.mapAttrs' (
          name: app:
          lib.nameValuePair (configId name) (
            if lib.isFunction app.config then
              {
                enrollments = lib.listToAttrs (
                  map (
                    d:
                    lib.nameValuePair d.udid {
                      content = toPlist (app.config d);
                      substitutions = lib.mapAttrs (_: secret: config.sops.secrets.${secret}.path) (app.secrets d);
                    }
                  ) (lib.filter (d: d.udid != null) deviceList)
                );
              }
            else
              { content = toPlist app.config; }
          )
        ) (lib.filterAttrs (_: app: app.config != { }) apps);
      in
      {
        imports = [
          ./_nanohub-module.nix
          ./_scep-module.nix
          ./_nanodep-module.nix
          ./_vpp-module.nix
        ];

        # Device licenses for the apps, for every device with a serial number.
        services.apple-vpp = lib.mkIf hasVpp {
          enable = true;
          tokenFile = secrets.devices-apple_vpp_token.path;
          assignments = lib.mapAttrs' (_: app: lib.nameValuePair app.storeId serials) apps;
        };

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
          # Every device asks for the same subject, so a second enrollment
          # (a device erased, or another one) would be refused: "DN ...
          # already exists". nanohub tells devices apart by their
          # certificate's hash, not its subject.
          allowRenewal = 0;
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

          declarations = allDeclarations // activations;
          sets = lib.mapAttrs (set: ids: ids ++ [ (activationId set) ]) sets;
          dataAssets = appConfigs // personAssets;
          profiles = allProfiles;
          dataAssetsURL = "https://${domain}/assets";
          # Each device's own configs: through nanohub, which checks it is
          # the device, to nginx on loopback (below).
          authProxyURL = "http://127.0.0.1:${toString assetPort}";
          privateDataAssetsURL = "https://${domain}/authproxy/assets";
          privateDataAssetsGroup = "nginx";
          # How the assets are served (below): a fix there makes devices
          # fetch them again.
          # A solid colour, made at build time: an iPhone screen's size.
          wallpaper = lib.mkIf (apple.wallpaper != null) {
            image = pkgs.runCommand "wallpaper.png" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
              magick -size 1290x2796 xc:${lib.escapeShellArg apple.wallpaper.color} png:$out
            '';
            inherit (apple.wallpaper) where;
          };
          # Every check-in, to apple-devices-metrics (below), for the
          # devices' answers about their battery and storage.
          webhookURL = "http://127.0.0.1:${toString metricsPort}/webhook";
          refetchTriggers = map builtins.toJSON [
            config.services.nginx.virtualHosts.${domain}.locations."/assets/"
            config.services.nginx.virtualHosts.devices-apple-assets.locations
          ];
          enrollmentSets = lib.listToAttrs (
            lib.mapAttrsToList (
              _: d:
              lib.nameValuePair d.udid (
                lib.unique (
                  [ "default" ]
                  ++ lib.optional (d.owner != null && (hasMail || hasCalendar)) (personSet d.owner)
                  ++ d.sets
                )
              )
            ) (lib.filterAttrs (_: d: d.udid != null) apple.devices)
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
        # The devices and their MDM as metrics, in node_exporter's textfile
        # directory (./metrics): monitoring (services/dash) has them, and
        # alerts on expiring Apple tokens and silent devices.
        systemd.services.apple-devices-metrics =
          let
            # systemd puts each credential here, by its name below.
            credential = name: "/run/credentials/apple-devices-metrics.service/${name}";
            configFile = pkgs.writeText "apple-devices-metrics.json" (
              builtins.toJSON (
                {
                  listen = "127.0.0.1:${toString metricsPort}";
                  output = "${config.ark.metrics.textfileDir}/apple_devices.prom";
                  nanohub = "http://127.0.0.1:${toString service.port}";
                  nanohubKey = credential "nanohub";
                  devices = map (d: {
                    inherit (d) name udid;
                    owner = if d.owner == null then "" else d.owner;
                  }) (lib.filter (d: d.udid != null) deviceList);
                }
                // lib.optionalAttrs hasToken {
                  depserver = "http://127.0.0.1:${toString depPort}";
                  depserverKey = credential "depserver";
                  depNames = [ "abm" ];
                }
                // lib.optionalAttrs hasPush { pushCert = credential "push"; }
                // lib.optionalAttrs hasVpp { vppToken = credential "vpp"; }
              )
            );
          in
          {
            description = "Apple devices and their MDM as metrics";
            wantedBy = [ "multi-user.target" ];
            after = [ "nanohub.service" ];
            path = [ pkgs.openssl ];
            restartTriggers = [ configFile ];
            serviceConfig = {
              ExecStart = "${
                lib.getExe (pkgs.callPackage ../../../_rust.nix { pname = "apple-devices-metrics"; })
              } ${configFile}";
              LoadCredential = [
                "nanohub:${secrets.devices-apple_api_key.path}"
              ]
              ++ lib.optional hasToken "depserver:${secrets.devices-apple_dep_api_key.path}"
              ++ lib.optional hasPush "push:${secrets.devices-apple_push_cert.path}"
              ++ lib.optional hasVpp "vpp:${secrets.devices-apple_vpp_token.path}";
              Restart = "on-failure";
              # Root only to write in the textfile directory, root's.
              ProtectSystem = "strict";
              ReadWritePaths = [ config.ark.metrics.textfileDir ];
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
          # Behind nanohub's auth proxy, on loopback: the device's own file,
          # by the enrollment ID nanohub found in its signature.
          devices-apple-assets = {
            listen = [
              {
                addr = "127.0.0.1";
                port = assetPort;
              }
            ];
            # A named capture: the regex in the `if` resets $1, which made
            # the path the device's directory, and nginx redirected (301).
            locations."~ ^/authproxy/assets/(?<asset>[A-Za-z0-9._-]+)$".extraConfig = ''
              if ($http_x_enrollment_id !~ "^[A-Za-z0-9-]+$") { return 403; }
              default_type application/x-plist;
              alias ${config.services.nanohub.privateDataAssetsDir}/$http_x_enrollment_id/$asset;
            '';
          };

          # Public: what devices talk to. "/" is nanohub (lib/services.nix).
          ${domain}.locations = {
            "/scep".proxyPass = "http://127.0.0.1:${toString scepPort}";
            "/api/".return = "404";
            # Apps' configs (data assets): public, named by their hash.
            # Each with the media type its declaration names, which the
            # device checks: nginx's own types would make a plist
            # application/octet-stream, and the device refuses it.
            "/assets/" = {
              alias = "${config.services.nanohub.dataAssetsDir}/";
              extraConfig = ''
                types {
                  application/x-plist plist;
                  application/json json;
                  application/x-apple-aspen-config mobileconfig;
                }
                default_type application/octet-stream;
              '';
            };
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
