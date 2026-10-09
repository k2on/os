# sivrad: a NixOS container (systemd-nspawn) on adam running an always-on
# Claude Code session, named after the owner's phone voice assistant it
# serves. An ark.services entry without a web endpoint (web = false: the
# channel is in the container, on the tailnet, so nothing for nginx): what
# it takes from the registry is the phone app's OIDC client, its secrets
# and the service-sivrad aspect adam includes. Files starting with `_`
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
      # The password of the headed browser's VNC screen (./_chrome.nix),
      # which people type into the noVNC page; ./_host.nix hands it to the
      # container, root-only. Eight characters because VNC's own
      # authentication uses no more: the rest of a longer one would be
      # ignored. The page is only on the tailnet.
      sivrad_vnc_password = {
        generate = "tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8";
        restartUnits = [ "sivrad-credentials.service" ];
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
  };
}
