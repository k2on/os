# Mail: Stalwart on the vps, which has the static address mail needs.
#
# Mailboxes are on the main domain (modules/domains.nix), aliases on the
# one with role = "secondary". Every person gets a mailbox, <person>@<domain>,
# and every group in ark.groups (secrets/ark.nix) a shared one,
# <group>@<domain>: its members see it inside their own account, under
# "Shared Folders/<group>", and may send as its address; nobody logs in to
# it.
#
# In a mail app: IMAP mail.<domain>:993 (TLS) and SMTP mail.<domain>:465
# (TLS), user name the person's username (not their address), password the
# mail_password_<person> secret (`ark secrets` makes it; `ark sops -d
# mail_password_<person>.yaml` shows it). Thunderbird (and other apps that
# look) fills all of that in from autoconfig.<domain>, given the address.
#
# Mail to the internet leaves through Scaleway Transactional Email (TEM),
# which signs it (DKIM) and sends it from addresses mail providers trust;
# the vps's own port 25 out is blocked anyway. (Amazon SES was the first
# choice, but AWS would not take the account out of its sandbox.) `ark push`
# does all of it, in one apply: subscribes the project to TEM's Essential
# plan (a free monthly allowance, then pay per mail), sets TEM up for the
# domain with its DNS records (DKIM, SPF, DMARC) and an IAM application
# whose API key may only send mail, and puts that key in its output
# mail_relay_login; `ark service mail relay` copies it into sops
# (secrets/vars/mail_relay.yaml) as Stalwart's SMTP login, which comin then
# deploys. Until it is there, Stalwart reads the files the vps had before
# (/var/lib/mail-relay). Scaleway checks the records by itself; `ark
# service mail status` (./cli) asks it to now if they have not passed yet,
# and says how much it sent. The Scaleway keys `ark push` uses are infra
# secrets (SCW_ACCESS_KEY, SCW_SECRET_KEY, SCW_DEFAULT_ORGANIZATION_ID,
# SCW_DEFAULT_PROJECT_ID), entered with `ark secrets`, for an API key that
# may manage TEM and IAM.
#
# Aliases: Bitwarden's username generator makes them ("Forwarded email
# alias", service addy.io, self-hosted server https://alias.<domain>, the
# domain <domain>, and the person's mail_alias_token_<person> as its API
# key: `ark service mail bitwarden <person>` prints all that). One is
# <site>-<5 letters and digits>@<domain> and delivers to whoever made it,
# who may also reply from it; once the login holding it is saved in a
# group's vault (services/pass), its mail goes to that group's mailbox, and
# back when it leaves. mail-aliases (./aliases, Rust) makes and keeps them,
# and writes Stalwart's accounts when Stalwart starts; Stalwart restarts
# whenever an alias changes (a few seconds; senders retry). `ark service mail
# aliases` lists them, `ark service mail alias <address> off` stops one.
#
# The settings are ./_settings.nix; `nix flake check` runs them in a real
# Stalwart, with mail-aliases (./_check.nix).
{ lib, config, ... }:
let
  ark = config.ark;
  persons = lib.attrNames ark.persons;
  # Mailboxes (<person>@, <group>@) are on the main domain, aliases on the
  # secondary one. Stalwart takes mail for both, and each is its own TEM
  # domain.
  domain = ark.mainDomain;
  aliasDomain =
    (lib.findFirst (
      d: d.role == "secondary"
    ) (throw "mail: no domain with role = \"secondary\" in ark.domains") ark.domains).domain;
  domains = [
    domain
    aliasDomain
  ];
  hostname = "mail.${domain}";
  passwordSecret = p: "mail_password_${p}";

  # TEM: the region (its only one), its SMTP endpoint (2465 is TLS from the
  # first byte, on a port the vps's provider leaves open), and terraform
  # names.
  region = "fr-par";
  temSmtp = "smtp.tem.scaleway.com";
  # The alias domain keeps the resource name from when it was the only
  # one, so terraform does not replace it (terranix has no `moved`).
  temName = d: if d == aliasDomain then "mail" else lib.replaceStrings [ "." "-" ] [ "_" "_" ] d;
  temDomain = d: "scaleway_tem_domain.${temName d}";
  # Where terraform writes Stalwart's login to TEM on the vps (below).
  relayDir = "/var/lib/mail-relay";
  domainsOutput = "mail_tem_domains";
  # The SMTP login TEM gives Stalwart, from the infra state into sops.
  relayOutput = "mail_relay_login";
  relaySecret = part: "mail_relay_${part}";

  # Aliases: Bitwarden's endpoint (public, through nginx), the internal one
  # (the tailnet: pass-vaults on adam, `ark service mail`), and the key the
  # internal one wants.
  aliasesHost = "alias.${aliasDomain}";
  aliasesPort = 8730;
  aliasesInternalPort = 8731;
  aliasesKey = "mail_aliases_key";
  tokenSecret = p: "mail_alias_token_${p}";
  # The mail host's name on the tailnet, as `ark hosts` has it.
  mailHost =
    let
      h = lib.findFirst (h: lib.elem "mail" h.services) null (lib.attrValues config.flake.arkHosts);
    in
    if h == null || h.ssh == null then null else lib.last (lib.splitString "@" h.ssh);
in
{
  config.perSystem =
    { pkgs, ... }:
    {
      checks.mail = pkgs.callPackage ./_check.nix {
        mail-aliases = pkgs.callPackage ./aliases/_package.nix { };
      };
    };

  # For `ark service mail` (./cli).
  config.flake.arkServiceConfig.mail = {
    inherit region domainsOutput relayOutput;
    inherit (config.ark.mail) aliases;
  };

  # For services/pass, which reports where aliases go. Not through `flake`,
  # which the services' secrets help make.
  options.ark.mail = lib.mkOption {
    type = lib.types.raw;
    readOnly = true;
    default = {
      inherit domain;
      aliases = {
        domain = aliasDomain;
        url = "https://${aliasesHost}";
        # Read only by hosts' own units, never while declaring secrets.
        endpoint = if mailHost == null then null else "http://${mailHost}:${toString aliasesInternalPort}";
        key = aliasesKey;
        tokens = lib.genAttrs persons tokenSecret;
      };
    };
    description = "Where mail and its aliases are, for other services.";
  };

  # The Scaleway provider, once for the whole infra; its keys are admin-only
  # infra secrets (lib/secrets.nix), exported to `ark plan/push`.
  config.den.aspects.mail-scaleway = {
    terranix = {
      terraform.required_providers.scaleway = {
        source = "scaleway/scaleway";
        version = "~> 2.0";
      };
      provider.scaleway = { inherit region; };
    };
    secrets = {
      SCW_ACCESS_KEY = { };
      SCW_SECRET_KEY = { };
      SCW_DEFAULT_ORGANIZATION_ID = { };
      SCW_DEFAULT_PROJECT_ID = { };
    };
  };
  config.den.aspects.infra-base.includes = [
    config.den.aspects.mail-scaleway
  ];

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
      # What Bitwarden sends for each person when it makes an alias.
      // lib.genAttrs' persons (
        p:
        lib.nameValuePair (tokenSecret p) {
          generate = true;
          owner = "stalwart";
          restartUnits = [ "mail-aliases.service" ];
        }
      )
      # Stalwart's SMTP login at TEM, filled in by `ark service mail relay`.
      // lib.genAttrs' [ "username" "password" ] (
        part:
        lib.nameValuePair (relaySecret part) {
          file = "mail_relay";
          optional = true;
          owner = "stalwart";
          restartUnits = [ "stalwart.service" ];
        }
      )
      # The internal API's key, shared with pass-vaults (services/pass).
      // {
        ${aliasesKey} = {
          generate = true;
          owner = "stalwart";
          restartUnits = [ "mail-aliases.service" ];
        };
      };

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
              ${lib.concatMapStrings (d: "<domain>${d}</domain>") domains}
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

        mailAliases = pkgs.callPackage ./aliases/_package.nix { };
        aliasesDir = "/var/lib/mail-aliases";
        aliasesChanged = "${aliasesDir}/changed";
        aliasesConfig = pkgs.writeText "mail-aliases.json" (
          builtins.toJSON {
            db = "${aliasesDir}/aliases.db";
            changedFile = aliasesChanged;
            domain = aliasDomain;
            listen = "127.0.0.1:${toString aliasesPort}";
            internalListen = "0.0.0.0:${toString aliasesInternalPort}";
            internalKeyFile = config.sops.secrets.${aliasesKey}.path;
            persons = map (p: {
              name = p;
              address = "${p}@${domain}";
              passwordFile = config.sops.secrets.${passwordSecret p}.path;
              tokenFile = config.sops.secrets.${tokenSecret p}.path;
              groups = lib.attrNames (lib.filterAttrs (_: members: lib.elem p members) ark.groups);
            }) persons;
            groups = lib.mapAttrsToList (name: _: {
              inherit name;
              address = "${name}@${domain}";
            }) ark.groups;
          }
        );
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
          # Its accounts are appended when it starts (systemd.services.stalwart).
          settings = import ./_settings.nix {
            inherit hostname domains;
            listen = {
              smtp = "[::]:25";
              submissions = "[::]:465";
              imaps = "[::]:993";
            };
            certFile = "${certDir}/fullchain.pem";
            keyFile = "${certDir}/key.pem";
            spamFilter = "file://${config.services.stalwart.package.spam-filter}/spam-filter.toml";
            # The login from sops once `ark service mail relay` has put it
            # there; until then the files terraform wrote onto the vps.
            relay =
              let
                fromSops = config.sops.secrets ? ${relaySecret "password"};
                file =
                  part: if fromSops then config.sops.secrets.${relaySecret part}.path else "${relayDir}/${part}";
              in
              {
                address = temSmtp;
                port = 2465;
                usernameFile = file "username";
                passwordFile = file "password";
              };
          };
        };

        # The certificate comes through nginx's port 80 (it already answers
        # there for headscale); Stalwart reads it as a member of nginx's group.
        # The site itself serves nothing, but answers HTTPS with the right
        # certificate: Thunderbird looks there too, and asks you about any
        # other. One certificate for mail.<each domain>: mail apps set up
        # with mail.<alias domain>, from before the mailboxes moved, keep
        # working.
        services.nginx.virtualHosts.${hostname} = httpsSite // {
          serverAliases = map (d: "mail.${d}") (lib.remove domain domains);
        };
        security.acme.certs.${hostname}.reloadServices = [ "stalwart.service" ];
        # A first order can come before its name resolves (`ark push` makes
        # the records and deploys together). Keep trying until it does, at
        # the 15 minutes NixOS spaces retries by (Let's Encrypt allows 5
        # failures an hour); Stalwart has a self-signed stand-in until then.
        systemd.services."acme-order-renew-${hostname}".serviceConfig.Restart = "on-failure";
        systemd.services."acme-order-renew-autoconfig.${domain}".serviceConfig.Restart = "on-failure";
        systemd.services."acme-order-renew-${aliasesHost}".serviceConfig.Restart = "on-failure";
        users.users.stalwart.extraGroups = [ config.services.nginx.group ];

        # Thunderbird asks for the settings above at both
        # autoconfig.<domain>/mail/ and <domain>/.well-known/autoconfig/mail/
        # (at once, and asks you about a bad certificate on either), before it
        # guesses. One site, one certificate for all those names; otherwise
        # the alias domain's bare name serves a page saying what the domain
        # is and who to write to (./homepage.html; relays look for one
        # before letting a domain send). The main domain's bare name is not
        # this server's, so Thunderbird finds it at autoconfig.<domain>.
        # %EMAILLOCALPART% makes the user name the part before the @.
        services.nginx.virtualHosts."autoconfig.${domain}" = httpsSite // {
          serverAliases = map (d: "autoconfig.${d}") (lib.remove domain domains) ++ [ aliasDomain ];
          locations =
            lib.genAttrs [ "= /mail/config-v1.1.xml" "= /.well-known/autoconfig/mail/config-v1.1.xml" ] (_: {
              alias = autoconfig;
              extraConfig = "default_type application/xml;";
            })
            // {
              "/".root = pkgs.writeTextDir "index.html" (
                builtins.replaceStrings [ "@domain@" ] [ aliasDomain ] (builtins.readFile ./homepage.html)
              );
            };
        };
        systemd.services.stalwart = {
          wants = [
            "acme-finished-${hostname}.target"
            "mail-aliases.service"
          ];
          after = [
            "acme-finished-${hostname}.target"
            "mail-aliases.service"
          ];
          # Stalwart writes its defaults back into the file it was started
          # with, which fails on the store's copy. A fresh writable copy each
          # start keeps the settings Nix's; its accounts, aliases included,
          # come after them.
          preStart = ''
            install -m 0600 ${configFile} /run/stalwart/config.toml
            ${lib.getExe mailAliases} render ${aliasesConfig} >> /run/stalwart/config.toml
          '';
          serviceConfig = {
            RuntimeDirectory = "stalwart";
            ReadWritePaths = [ aliasesDir ];
            ExecStart = lib.mkForce [
              ""
              "${lib.getExe config.services.stalwart.package} --config=/run/stalwart/config.toml"
            ];
          };
        };

        # Aliases: Bitwarden's API, and the tailnet's.
        systemd.tmpfiles.rules = [
          "d ${aliasesDir} 0700 stalwart stalwart - -"
          "d ${relayDir} 0700 stalwart stalwart - -"
        ];
        systemd.services.mail-aliases = {
          description = "Mail aliases from Bitwarden";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            User = "stalwart";
            Group = "stalwart";
            ExecStart = "${lib.getExe mailAliases} serve ${aliasesConfig}";
            Restart = "on-failure";
            RestartSec = 5;
            ReadWritePaths = [ aliasesDir ];
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
          };
        };
        # Stalwart reads its accounts when it starts, so an alias changing
        # restarts it.
        systemd.paths.stalwart-accounts = {
          wantedBy = [ "paths.target" ];
          pathConfig.PathChanged = aliasesChanged;
        };
        systemd.services.stalwart-accounts = {
          description = "Restart Stalwart for changed aliases";
          serviceConfig.Type = "oneshot";
          script = "systemctl try-restart stalwart.service";
        };
        services.nginx.virtualHosts.${aliasesHost} = httpsSite // {
          locations."/api/".proxyPass = "http://127.0.0.1:${toString aliasesPort}";
        };
        networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ aliasesInternalPort ];

        networking.firewall.allowedTCPPorts = [
          25 # mail from the internet
          465 # mail apps sending
          993 # mail apps reading
        ];
      };
  };

  # The host-specific half: the names pointing at the vps that runs it, and
  # TEM for its domains.
  config.den.aspects.mail =
    { host, ... }:
    let
      # Every domain's records, on whichever DNS provider has it (record ids
      # need only be unique per provider).
      records = d: [
        {
          domain = d;
          id = "spf";
          name = "";
          type = "TXT";
          # Not the provider's spf_value: TEM builds that from whatever SPF
          # the domain had when it was added (SES's, on the alias domain),
          # and keeps it.
          content = "v=spf1 include:_spf.tem.scaleway.com ~all";
        }
        {
          domain = d;
          name = "_dmarc";
          type = "TXT";
          content = "v=DMARC1; p=quarantine";
        }
        {
          domain = d;
          id = "dkim";
          name = "\${${temDomain d}.project_id}._domainkey";
          type = "TXT";
          content = "\${${temDomain d}.dkim_config}";
        }
        {
          domain = d;
          name = "mail";
          type = "A";
          content = ark.vps.ip host;
        }
        {
          domain = d;
          name = "autoconfig";
          type = "A";
          content = ark.vps.ip host;
        }
        {
          domain = d;
          id = "mx";
          name = "";
          type = "MX";
          content = "mail.${d}";
          priority = 10;
        }
      ];
    in
    {
      includes = [ config.den.aspects.service-mail ];

      terranix = {
        # Each domain, signed by TEM's DKIM key (its TXT record below, at
        # <project id>._domainkey: the provider's dkim_name is the full name,
        # with a trailing dot, and the DNS providers want it relative).
        # Scaleway checks the records by itself, and again when `ark service
        # mail status` asks.
        resource.scaleway_tem_domain = lib.listToAttrs (
          map (d: {
            name = temName d;
            value = {
              name = d;
              accept_tos = true;
              depends_on = [ "terraform_data.mail_tem_offer" ];
            };
          }) domains
        );
        # TEM takes no domain in a project without a plan, and the provider
        # can only read one: subscribe with the Scaleway CLI, which reads
        # the same SCW_* keys from the environment. Subscribing again to the
        # plan the project has changes nothing.
        resource.terraform_data.mail_tem_offer = {
          input = "essential";
          provisioner.local-exec.command = "nix run nixpkgs#scaleway-cli -- tem offers update name=essential region=${region}";
        };

        # Stalwart's login: an application limited to TEM in the domains'
        # project (one login sends for all of them).
        # TransactionalEmailEmailApiCreate, the narrowest set, sends through
        # the API only: SMTP refuses it with "535 Permission denied".
        resource.scaleway_iam_application.mail.name = "ark-mail-smtp";
        resource.scaleway_iam_policy.mail = {
          name = "send-as-${domain}";
          application_id = "\${scaleway_iam_application.mail.id}";
          rule = [
            {
              project_ids = [ "\${${temDomain domain}.project_id}" ];
              permission_set_names = [ "TransactionalEmailFullAccess" ];
            }
          ];
        };
        resource.scaleway_iam_api_key.mail = {
          application_id = "\${scaleway_iam_application.mail.id}";
          description = "Stalwart's SMTP login on the vps";
          # Scaleway gives a key a year (this one: until 2027-10-31), and an
          # expiry cannot be removed, only the key replaced: so the expiry is
          # left as Scaleway set it. Mail stops relaying when it passes; replace
          # the key before then (tofu -chdir=infra apply -replace=scaleway_iam_api_key.mail),
          # then `ark service mail relay` to give Stalwart the new one.
          lifecycle.ignore_changes = [ "expires_at" ];
        };
        # Stalwart's SMTP login: the project's id and the key's secret, for
        # `ark service mail relay` to copy into sops. Sensitive: tofu shows it
        # only when asked for it by name.
        output.${relayOutput} = {
          value = {
            username = "\${${temDomain domain}.smtps_auth_user}";
            password = "\${scaleway_iam_api_key.mail.secret_key}";
          };
          sensitive = true;
        };
        # For `ark service mail status`: each domain's TEM id.
        output.${domainsOutput}.value = lib.genAttrs domains (d: "\${${temDomain d}.id}");
      };

      dns_records = lib.concatMap records domains ++ [
        {
          domain = aliasDomain;
          name = "alias";
          type = "A";
          content = ark.vps.ip host;
        }
      ];
    };
}
