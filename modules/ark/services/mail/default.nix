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
# Mail to the internet leaves through Amazon SES, which signs it (DKIM) and
# sends it from addresses mail providers trust; the vps's own port 25 out is
# blocked anyway. `ark push` sets SES up for the domain, with its DNS records
# (DKIM, a bounce.<domain> MAIL FROM, SPF, DMARC) and an IAM user that may
# only send as it. `ark service mail init` (./cli) then stores that user's
# SMTP login (mail_ses_*, which benj builds without until then) and asks AWS
# to take the account out of the sandbox, a review by a person that takes
# about a day; until it passes, SES only delivers to addresses verified in
# it. `ark service mail status` says where that stands. Another `ark push`
# after init turns the relay on. The AWS keys `ark push` uses are infra
# secrets (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY), entered with `ark
# secrets`, for an IAM user that may manage SES and IAM.
#
# The settings are ./_settings.nix; `nix flake check` runs them in a real
# Stalwart (./_check.nix).
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

  # SES: the region, its SMTP endpoint (2465 is TLS from the first byte, on
  # a port the vps's provider leaves open), and terraform names.
  region = "us-east-1";
  sesSmtp = "email-smtp.${region}.amazonaws.com";
  identity = "aws_sesv2_email_identity.mail";
  sesOutput = "mail_ses_smtp";
  sesSecret = field: "mail_ses_${field}";
in
{
  config.perSystem =
    { pkgs, ... }:
    {
      checks.mail = pkgs.callPackage ./_check.nix { };
    };

  # For `ark service mail` (./cli).
  config.flake.arkServiceConfig.mail = {
    inherit domain region sesOutput;
    secrets = {
      username = sesSecret "username";
      password = sesSecret "password";
    };
  };

  # The AWS provider, once for the whole infra; its keys are admin-only
  # infra secrets (lib/secrets.nix), exported to `ark plan/push`.
  config.den.aspects.mail-aws = {
    terranix = {
      terraform.required_providers.aws = {
        source = "hashicorp/aws";
        version = "~> 6.0";
      };
      provider.aws = { inherit region; };
    };
    secrets = {
      AWS_ACCESS_KEY_ID = { };
      AWS_SECRET_ACCESS_KEY = { };
    };
  };
  config.den.aspects.infra-base.includes = [ config.den.aspects.mail-aws ];

  config.ark.services.mail = {
    web = false;
    secrets =
      lib.genAttrs' persons (
        p:
        lib.nameValuePair (passwordSecret p) {
          generate = "tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24";
          owner = "stalwart";
          restartUnits = [ "stalwart.service" ];
        }
      )
      # The SES SMTP login, from `ark service mail init`.
      // lib.genAttrs' [ "username" "password" ] (
        field:
        lib.nameValuePair (sesSecret field) {
          file = "mail_ses";
          optional = true;
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
            # Once `ark service mail init` has stored the login.
            relay =
              if config.sops.secrets ? ${sesSecret "password"} then
                {
                  address = sesSmtp;
                  port = 2465;
                  usernameFile = config.sops.secrets.${sesSecret "username"}.path;
                  passwordFile = config.sops.secrets.${sesSecret "password"}.path;
                }
              else
                null;
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

  # The host-specific half: the names pointing at the vps that runs it, and
  # SES for its domain.
  config.den.aspects.mail =
    { host, ... }:
    {
      includes = [ config.den.aspects.service-mail ];

      terranix = {
        # The domain, signed by SES's own DKIM keys (the CNAMEs below), with
        # bounces coming back to bounce.<domain> so SPF lines up with it.
        resource.aws_sesv2_email_identity.mail.email_identity = domain;
        resource.aws_sesv2_email_identity_mail_from_attributes.mail = {
          email_identity = "\${${identity}.email_identity}";
          mail_from_domain = "bounce.${domain}";
          behavior_on_mx_failure = "USE_DEFAULT_VALUE";
        };

        # Stalwart's login: may send as the domain and nothing else.
        resource.aws_iam_user.mail.name = "ark-mail-smtp";
        resource.aws_iam_user_policy.mail = {
          name = "send-as-${domain}";
          user = "\${aws_iam_user.mail.name}";
          policy = builtins.toJSON {
            Version = "2012-10-17";
            Statement = [
              {
                Effect = "Allow";
                Action = "ses:SendRawEmail";
                Resource = "*";
                Condition.StringLike."ses:FromAddress" = "*@${domain}";
              }
            ];
          };
        };
        resource.aws_iam_access_key.mail.user = "\${aws_iam_user.mail.name}";
        # What `ark service mail init` stores (SMTP wants the key's id and a
        # password derived from its secret for the region).
        output.${sesOutput} = {
          sensitive = true;
          value = {
            username = "\${aws_iam_access_key.mail.id}";
            password = "\${aws_iam_access_key.mail.ses_smtp_password_v4}";
          };
        };
      };

      dns_records = [
        {
          inherit domain;
          id = "spf";
          name = "";
          type = "TXT";
          content = "v=spf1 include:amazonses.com ~all";
        }
        {
          inherit domain;
          name = "_dmarc";
          type = "TXT";
          content = "v=DMARC1; p=quarantine";
        }
        {
          inherit domain;
          id = "bounce_mx";
          name = "bounce";
          type = "MX";
          content = "feedback-smtp.${region}.amazonses.com";
          priority = 10;
        }
        {
          inherit domain;
          id = "bounce_spf";
          name = "bounce";
          type = "TXT";
          content = "v=spf1 include:amazonses.com ~all";
        }
      ]
      ++
        map
          (
            i:
            let
              token = "\${${identity}.dkim_signing_attributes[0].tokens[${toString i}]}";
            in
            {
              inherit domain;
              id = "dkim${toString i}";
              name = "${token}._domainkey";
              type = "CNAME";
              content = "${token}.dkim.amazonses.com";
            }
          )
          [
            0
            1
            2
          ]
      ++ [
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
