# Mail: Stalwart on the vps, which has the static address mail needs.
#
# On the domain with role = "secondary" (modules/domains.nix) for now.
# Every person gets a mailbox, <person>@<domain>, and every group in
# ark.groups (secrets/ark.nix) a shared one, <group>@<domain>: its members
# see it inside their own account, under "Shared Folders/<group>", and may
# send as its address; nobody logs in to it.
#
# In a mail app: IMAP mail.<domain>:993 (TLS) and SMTP mail.<domain>:465
# (TLS), user name the person's username (not their address), password the
# mail_password_<person> secret (`ark secrets` makes it; `ark sops -d
# mail_password_<person>.yaml` shows it). Thunderbird (and other apps that
# look) fills all of that in from autoconfig.<domain>, given the address.
#
# The settings are ./_settings.nix; `nix flake check` runs them in a real
# Stalwart (./_check.nix). Sending to the internet goes out directly for now:
# the vps's provider blocks port 25 until asked, and nothing signs it yet.
{ lib, config, ... }:
let
  ark = config.ark;
  persons = lib.attrNames ark.persons;
  domain =
    (lib.findFirst (
      d: d.role == "secondary"
    ) (throw "mail: no domain with role = \"secondary\" in ark.domains") ark.domains).domain;
  hostname = "mail.${domain}";
  passwordSecret = p: "mail_password_${p}";
in
{
  config.perSystem =
    { pkgs, ... }:
    {
      checks.mail = pkgs.callPackage ./_check.nix { };
    };

  config.ark.services.mail = {
    web = false;
    secrets = lib.genAttrs' persons (
      p:
      lib.nameValuePair (passwordSecret p) {
        generate = "tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24";
        owner = "stalwart";
        restartUnits = [ "stalwart.service" ];
      }
    );

    nixos =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        configFile = (pkgs.formats.toml { }).generate "stalwart.toml" config.services.stalwart.settings;
        # A site on the vps with its own Let's Encrypt certificate. HTTPS on
        # 443 is headscale's stream router (services/headscale), which hands
        # names it does not pass to ark to 127.0.0.1:8444; listening on
        # 0.0.0.0 there loses to that more specific address.
        httpsSite = {
          enableACME = true;
          forceSSL = true;
          listen = [
            {
              addr = "0.0.0.0";
              port = 80;
            }
            {
              addr = "[::]";
              port = 80;
            }
            {
              addr = "127.0.0.1";
              port = 8444;
              ssl = true;
            }
          ];
        };
        server = port: ''
          <hostname>${hostname}</hostname>
          <port>${toString port}</port>
          <socketType>SSL</socketType>
          <username>%EMAILLOCALPART%</username>
          <authentication>password-cleartext</authentication>
        '';
        autoconfig = pkgs.writeText "config-v1.1.xml" ''
          <?xml version="1.0" encoding="UTF-8"?>
          <clientConfig version="1.1">
            <emailProvider id="${domain}">
              <domain>${domain}</domain>
              <displayName>${domain}</displayName>
              <incomingServer type="imap">
              ${server 993}</incomingServer>
              <outgoingServer type="smtp">
              ${server 465}</outgoingServer>
            </emailProvider>
          </clientConfig>
        '';
        clash = lib.intersectLists persons (lib.attrNames ark.groups);
        certDir = config.security.acme.certs.${hostname}.directory;
      in
      {
        assertions = [
          {
            assertion = clash == [ ];
            message = "mail: ${toString clash} is both a person and a group, and so one address";
          }
        ];

        services.stalwart = {
          enable = true;
          stateVersion = "26.05";
          settings = import ./_settings.nix {
            inherit hostname;
            mailboxes = map (p: {
              name = p;
              address = "${p}@${domain}";
              passwordFile = config.sops.secrets.${passwordSecret p}.path;
              memberOf = lib.attrNames (lib.filterAttrs (_: members: lib.elem p members) ark.groups);
            }) persons;
            shared = lib.mapAttrsToList (name: _: {
              inherit name;
              address = "${name}@${domain}";
            }) ark.groups;
            listen = {
              smtp = "[::]:25";
              submissions = "[::]:465";
              imaps = "[::]:993";
            };
            certFile = "${certDir}/fullchain.pem";
            keyFile = "${certDir}/key.pem";
            spamFilter = "file://${config.services.stalwart.package.spam-filter}/spam-filter.toml";
          };
        };

        # The certificate comes through nginx's port 80 (it already answers
        # there for headscale); Stalwart reads it as a member of nginx's group.
        # The site itself serves nothing, but answers HTTPS with the right
        # certificate: Thunderbird looks there too, and asks you about any
        # other.
        services.nginx.virtualHosts.${hostname} = httpsSite;
        security.acme.certs.${hostname}.reloadServices = [ "stalwart.service" ];
        # A first order can come before its name resolves (`ark push` makes
        # the records and deploys together). Keep trying until it does, at
        # the 15 minutes NixOS spaces retries by (Let's Encrypt allows 5
        # failures an hour); Stalwart has a self-signed stand-in until then.
        systemd.services."acme-order-renew-${hostname}".serviceConfig.Restart = "on-failure";
        systemd.services."acme-order-renew-autoconfig.${domain}".serviceConfig.Restart = "on-failure";
        users.users.stalwart.extraGroups = [ config.services.nginx.group ];

        # Thunderbird asks for the settings above at both
        # autoconfig.<domain>/mail/ and <domain>/.well-known/autoconfig/mail/
        # (at once, and asks you about a bad certificate on either), before it
        # guesses. One site, one certificate for both names; the bare domain
        # serves nothing else. %EMAILLOCALPART% makes the user name the part
        # before the @.
        services.nginx.virtualHosts."autoconfig.${domain}" = httpsSite // {
          serverAliases = [ domain ];
          locations =
            lib.genAttrs [ "= /mail/config-v1.1.xml" "= /.well-known/autoconfig/mail/config-v1.1.xml" ]
              (_: {
                alias = autoconfig;
                extraConfig = "default_type application/xml;";
              });
        };
        systemd.services.stalwart = {
          wants = [ "acme-finished-${hostname}.target" ];
          after = [ "acme-finished-${hostname}.target" ];
          # Stalwart writes its defaults back into the file it was started
          # with, which fails on the store's copy. A fresh writable copy each
          # start keeps the settings Nix's.
          preStart = "install -m 0600 ${configFile} /run/stalwart/config.toml";
          serviceConfig = {
            RuntimeDirectory = "stalwart";
            ExecStart = lib.mkForce [
              ""
              "${lib.getExe config.services.stalwart.package} --config=/run/stalwart/config.toml"
            ];
          };
        };

        networking.firewall.allowedTCPPorts = [
          25 # mail from the internet
          465 # mail apps sending
          993 # mail apps reading
        ];
      };
  };

  # The host-specific half: the names pointing at the vps that runs it.
  config.den.aspects.mail =
    { host, ... }:
    {
      includes = [ config.den.aspects.service-mail ];

      dns_records = [
        {
          inherit domain;
          name = "mail";
          type = "A";
          content = ark.vps.ip host;
        }
        {
          inherit domain;
          name = "autoconfig";
          type = "A";
          content = ark.vps.ip host;
        }
        {
          inherit domain;
          id = "mx";
          name = "";
          type = "MX";
          content = hostname;
          priority = 10;
        }
      ];
    };
}
