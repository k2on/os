# sivrad: a NixOS container (systemd-nspawn) on adam running an always-on
# Claude Code session, named after the owner's phone voice assistant it
# serves.
# Not an ark.services entry (no HTTP service behind nginx): it defines the
# Den aspect den.aspects.sivrad directly. Files starting with `_` carry the
# underscore so import-tree does not load them as flake modules.
#
# Who may use sivrad: everyone in secrets/ark.nix with a Signal number, or a
# Signal username for someone who does not share their number,
#
#   ark.persons.alice.signal = "+15551234567";
#   ark.persons.bob.signal = "bob.42";
#
# (lib/oidc.nix). They make up the Kanidm group sivrad_users, which may sign
# in to the phone app (./_kanidm.nix), and the channel's people.json, which
# maps their numbers to their usernames (./_guest.nix). There is no command
# for it: edit secrets/ark.nix, commit it and deploy adam, then restart the
# container (`systemctl restart container@sivrad`) for the channel to see
# the change.
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
  config.den.aspects.sivrad = {
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
    };

    nixos = {
      imports = [
        ./_host.nix
        (import ./_kanidm.nix {
          origin = idOrigin;
          members = lib.attrNames people;
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
        oidc = {
          issuer = "${idOrigin}/oauth2/openid/sivrad";
          clientId = "sivrad";
        };
        # The Signal account's profile, applied on start (./_guest.nix): its
        # name, and ./avatar.png as its picture when that file exists.
        signalProfile = {
          givenName = "Sivrad";
          avatar = if builtins.pathExists ./avatar.png then ./avatar.png else null;
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
