# sivrad: a NixOS container (systemd-nspawn) on adam running an always-on
# Claude Code session, named after the owner's phone voice assistant it
# serves. An ark.services entry without a web endpoint (web = false: the
# channel is in the container, on the tailnet, so nothing for nginx): what
# it takes from the registry is the phone app's OIDC client, its secrets
# and the service-sivrad aspect adam includes. A second entry,
# sivrad-browser (below), is the web side: the headed browser's page,
# behind a Kanidm sign-in, with service-sivrad-browser. Files starting with `_`
# carry the underscore so import-tree does not load them as flake modules.
#
# Who may use sivrad: everyone in secrets/ark.nix with a Signal number, or a
# Signal username for someone who does not share their number,
#
#   ark.persons.alice.signal = "+15551234567";
#   ark.persons.bob.signal = "bob.42";
#
# (lib/oidc.nix). They make up the Kanidm group sivrad_users, which may sign
# in to the phone app (the client below), and the channel's people.json,
# which maps their numbers to their usernames (./_guest.nix). There is no
# command for it: edit secrets/ark.nix, commit it and deploy adam, then
# restart the container (`systemctl restart container@sivrad`) for the
# channel to see the change.
#
# The assistant has an account of its own, `sivrad` (./_bot.nix): a Kanidm
# person (./_kanidm.nix) in the members groups of the services it may use,
# each of which mints it an API token (<service>/_tokens.nix). The container
# gets the password, the TOTP secret and the tokens as files (./_host.nix).
#
# The rest is set up from a laptop with `ark service sivrad ...`
# (./cli/mod.rs), which drives the container over ssh and keeps the Signal
# account in the secrets repo:
#
#   ark service sivrad init                  # the Claude login, and what is
#                                            # still missing
#   ark service sivrad signal register +15557654321
#
# then commit secrets/ and deploy adam.
{ config, lib, ... }:
let
  ark = config.ark;
  container = import ./_container.nix;
  # The assistant's own account and the services it may use.
  bot = import ./_bot.nix;
  # Everyone who may use sivrad: the persons with a Signal number.
  people = lib.filterAttrs (_: p: p.signal != null) ark.persons;
  # E.164, as the channel and signal-cli expect: + and the country code; or
  # a Signal username (name.NN) for someone who does not share their number.
  invalid = lib.attrNames (
    lib.filterAttrs (
      _: p: builtins.match "[+][1-9][0-9]{6,14}|[a-zA-Z_][a-zA-Z0-9_]{2,31}[.][0-9]{2,9}" p.signal == null
    ) people
  );
  # The channel tells Signal senders apart by their number or username.
  shared = lib.filterAttrs (_: names: lib.length names > 1) (
    lib.groupBy (name: people.${name}.signal) (lib.attrNames people)
  );
  # Kanidm's per-client issuer, as in lib/oidc.nix.
  idOrigin = "https://id.${ark.mainDomain}";
  # Who may open the headed browser's page (sivrad-browser below): Kanidm
  # usernames, Max's decision rather than a list in secrets/ark.nix.
  browserPeople = [
    "max"
    "heather"
  ];
  unknownBrowserPeople = lib.filter (p: !(ark.persons ? ${p})) browserPeople;
  browserPage = {
    url = "https://${ark.serviceDomain "sivrad-browser" ark.services.sivrad-browser}";
    people = browserPeople;
  };

  # The container's MagicDNS name: headscale's base_domain, read off the host that
  # runs headscale, the way lib/services.nix derives the arkHosts ssh targets.
  tailnetDomain = lib.findFirst (d: d != null) null (
    lib.mapAttrsToList (_: h: h.config.services.headscale.settings.dns.base_domain or null) (
      lib.filterAttrs (
        _: h: h.config ? ark && lib.elem "headscale" (h.config.ark.hostedServices or [ ])
      ) config.flake.nixosConfigurations
    )
  );
in
{
  config.ark.services.sivrad = {
    web = false;

    # The phone app's sign-in: a public client (PKCE enforced, no client
    # secret) that redirects to the app's custom scheme. Not named after
    # the service: Kanidm names are unique across clients and persons, and
    # `sivrad` is the assistant's account. The channel checks the app's
    # access token against this client's userinfo endpoint
    # (./channel/src/oidc.rs).
    oidc = {
      clientId = "sivrad-app";
      public = true;
      displayName = "Sivrad";
      callbacks = [ "sivrad://oauth/callback" ];
      landing = idOrigin;
      # Who may sign in: the Kanidm group sivrad_users, which is not a group
      # in secrets/ark.nix but the people above.
      groups.users = lib.attrNames people;
    };

    secrets = {
      # The container's Signal identity, saved by `ark service sivrad signal
      # ...` after registering, so a rebuilt container comes back as the same
      # account: the number, and signal-cli's data directory as a base64
      # tar.gz, which the guest unpacks when it has no account yet
      # (./_guest.nix). Empty until then; one file, so the CLI reads and
      # writes both with a single yubikey touch.
      sivrad_signal_number = {
        file = "sivrad_signal";
        generate = "printf ''";
      };
      sivrad_signal_account = {
        file = "sivrad_signal";
        generate = "printf ''";
        restartUnits = [ "sivrad-credentials.service" ];
      };
      # The account's Kanidm password (./_bot.nix), set in Kanidm and
      # handed to the container by ./_kanidm.nix.
      sivrad_password = {
        generate = true;
        restartUnits = [ "sivrad-kanidm-account.service" ];
      };
    };

    nixos =
      { service, ... }:
      {
        imports = [
          ./_host.nix
          (import ./_kanidm.nix {
            origin = idOrigin;
            inherit bot;
            mail = bot.mail ark.mainDomain;
            # The members group of each service it may use.
            groups = map (s: ark.oidc.clients.${s}.groups.members.name) bot.services;
          })
        ];
        assertions = [
          {
            assertion = invalid == [ ];
            message = "ark.persons.<name>.signal must be E.164 (+ and the country code, digits only, e.g. +15551234567) or a Signal username (e.g. alice.42); not so for: ${lib.concatStringsSep ", " invalid}";
          }
          {
            assertion = shared == { };
            message = "ark.persons: a Signal number or username belongs to one person only; shared by: ${lib.concatStringsSep "; " (map (lib.concatStringsSep ", ") (lib.attrValues shared))}";
          }
        ];
        containers.sivrad.specialArgs = {
          # Who may use sivrad, for the channel's people.json (./_guest.nix):
          # { "<username>": { "signal": "+..." } }.
          people = lib.mapAttrs (_: p: { inherit (p) signal; }) people;
          # Same login server as den.aspects.tailnet.
          loginServer = "https://${ark.serviceDomain "headscale" ark.services.headscale}";
          # The phone app's client, for the channel to check its tokens.
          oidc = { inherit (service.oidc) issuer clientId; };
          # The headed browser's page and who may open it, for the
          # assistant's CLAUDE.md (./_guest.nix).
          inherit browserPage;
          # The Signal account's profile, applied on start (./_guest.nix): its
          # name, and ./avatar.png as its picture when that file exists.
          signalProfile = {
            givenName = "Sivrad";
            avatar = if builtins.pathExists ./avatar.png then ./avatar.png else null;
          };
          # The assistant's own account (./_bot.nix) as the container sees
          # it: its Kanidm password and TOTP secret, and each service's URL
          # and API token, files under /run/host-tokens (adam's tokensDir,
          # bind-mounted by ./_host.nix; the tokens come from each service's
          # _tokens.nix).
          bot = {
            inherit (bot) name;
            kanidm = idOrigin;
            password = "/run/host-tokens/password";
            totp = "/run/host-tokens/totp";
            totpAlgo = bot.totp.algo;
            services = lib.genAttrs bot.services (s: {
              url = "https://${ark.serviceDomain s ark.services.${s}}";
              token = "/run/host-tokens/${s}";
            });
          };
        };
      };
  };

  # The headed browser's noVNC page (./_chrome.nix), where people watch the
  # browser and take it over: public at https://browser.sivrad.<mainDomain>,
  # for Max and Heather only, who sign in with Kanidm first. A service of
  # its own because it needs what sivrad has not got: a web endpoint (port,
  # nginx vhost, DNS name) and a second, confidential OIDC client, while
  # sivrad's one `oidc` is the phone app's public client. Its Kanidm client
  # is `sivrad-browser` and its group `sivrad-browser_users`, which is
  # browserPeople above (derived, like sivrad_users, not from
  # secrets/ark.nix; so the sivrad account, which is in the members groups
  # of the services it uses, is never in it).
  #
  # nginx (the generic vhost, lib/services.nix and host/adam/nginx.nix)
  # terminates TLS and passes everything, WebSockets included, to
  # oauth2-proxy on service.port, which signs people in with Kanidm, admits
  # only that group's claim, and proxies the rest to websockify in the
  # container over the veth (./_container.nix, ./_host.nix). Kanidm only
  # hands this client's tokens to members of the group in the first place
  # (its scope map, host/adam/kanidm.nix); oauth2-proxy checks again.
  #
  # Public: the vps passes browser.sivrad.* through to ark's nginx
  # (lib/public.nix); on the tailnet the name resolves to ark directly, as
  # every service's does. The name is two labels under mainDomain, which
  # the wildcard certificate does not cover; aspects/acme.nix adds such
  # names to it.
  config.ark.public."browser.sivrad" = 443;

  config.ark.services.sivrad-browser = {
    domain = "browser.sivrad.${ark.mainDomain}";

    oidc = {
      displayName = "Sivrad's browser";
      callbacks = [ "/oauth2/callback" ];
      groups.users = browserPeople;
    };

    # oauth2-proxy's cookie secret: 32 characters, as AES wants 16, 24 or
    # 32 bytes (the default 48 would not do).
    secrets.sivrad-browser_cookie_secret = {
      generate = "tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32";
      restartUnits = [ "oauth2-proxy.service" ];
    };

    nixos =
      {
        service,
        config,
        lib,
        ...
      }:
      {
        assertions = [
          {
            assertion = unknownBrowserPeople == [ ];
            message = "sivrad-browser: not in ark.persons (secrets/ark.nix): ${lib.concatStringsSep ", " unknownBrowserPeople}";
          }
        ];

        # Both secret files are root's; the module hands them to the
        # service with LoadCredential.
        services.oauth2-proxy = {
          enable = true;
          provider = "oidc";
          clientID = service.oidc.clientId;
          clientSecretFile = service.oidc.clientSecretFile;
          oidcIssuerUrl = service.oidc.issuer;
          redirectURL = "https://${service.domain}/oauth2/callback";
          scope = lib.concatStringsSep " " service.oidc.scopes;
          # No consent screen on every sign-in.
          approvalPrompt = "auto";
          # Who gets in is the group below, not the address.
          email.domains = [ "*" ];
          cookie.secretFile = config.sops.secrets.sivrad-browser_cookie_secret.path;
          httpAddress = "http://127.0.0.1:${toString service.port}";
          upstream = [ "http://${container.localAddress}:${toString container.novncPort}/" ];
          # Behind nginx on the same host, which sets X-Forwarded-*.
          reverseProxy = true;
          trustedProxyIP = [ "127.0.0.1" ];
          # websockify needs nobody's name or credentials.
          passBasicAuth = false;
          extraConfig = {
            allowed-group = service.oidc.groups.users.claim;
            # Kanidm enforces PKCE.
            code-challenge-method = "S256";
            # Straight to Kanidm, without oauth2-proxy's own "sign in" page.
            skip-provider-button = true;
          };
        };
        # It reads Kanidm's discovery document on start and exits when it
        # cannot; keep trying slowly rather than hitting the start limit.
        systemd.services.oauth2-proxy = {
          after = [ "kanidm.service" ];
          serviceConfig.RestartSec = "5s";
        };

        # The VNC session is one long WebSocket, which may sit quiet while
        # nothing on the screen changes: no 60-second read timeout on it.
        services.nginx.virtualHosts.${service.domain}.locations."/".extraConfig = ''
          proxy_read_timeout 1d;
          proxy_send_timeout 1d;
        '';
      };
  };

  # What `ark service sivrad ...` reads (cli/mod.rs), through `nix eval`.
  config.flake.arkServiceConfig.sivrad = {
    # ssh target: the container's own tailnet node; null without headscale.
    host = if tailnetDomain == null then null else "${container.name}.${tailnetDomain}";
    inherit (container) user;
    signal = {
      configDir = container.signalDir;
      socket = container.signalSocket;
    };
    # Who may use sivrad (ark.persons with a Signal number), for `init`.
    people = lib.attrNames people;
    # The headed browser's page and who may open it, for `init`.
    browser = browserPage;
  };
}
