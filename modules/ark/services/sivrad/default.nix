# sivrad: a microVM on adam running an always-on Claude Code session, named
# after the owner's phone voice assistant it serves.
# Not an ark.services entry (no HTTP service behind nginx): it defines the
# Den aspect den.aspects.sivrad directly. Files starting with `_` carry the
# underscore so import-tree does not load them as flake modules.
#
# Who may use sivrad: everyone in secrets/ark.nix with a Signal number,
#
#   ark.persons.alice.signal = "+15551234567";
#
# (lib/oidc.nix). They make up the Kanidm group sivrad_users, which may sign
# in to the phone app (./_kanidm.nix), and the channel's people.json, which
# maps their numbers to their usernames (./_guest.nix). There is no command
# for it: edit secrets/ark.nix, commit it and deploy adam, then restart the
# VM (`systemctl restart microvm@sivrad`) for the channel to see the change.
#
# The rest is set up from a laptop with `ark service sivrad ...`
# (./cli/mod.rs), which drives the VM over ssh and keeps the Signal account
# in the secrets repo:
#
#   ark service sivrad init                  # the Claude login, and what is
#                                            # still missing
#   ark service sivrad signal register +15557654321
#
# then commit secrets/ and deploy adam.
{
  inputs,
  config,
  lib,
  ...
}:
let
  ark = config.ark;
  vm = import ./_vm.nix;
  # Everyone who may use sivrad: the persons with a Signal number.
  people = lib.filterAttrs (_: p: p.signal != null) ark.persons;
  # E.164, as the channel and signal-cli expect: + and the country code.
  notE164 = lib.attrNames (
    lib.filterAttrs (_: p: builtins.match "[+][1-9][0-9]{6,14}" p.signal == null) people
  );
  # The channel tells Signal senders apart by their number.
  shared = lib.filterAttrs (_: names: lib.length names > 1) (
    lib.groupBy (name: people.${name}.signal) (lib.attrNames people)
  );
  # Kanidm's per-client issuer, as in lib/oidc.nix.
  idOrigin = "https://id.${ark.mainDomain}";

  # The VM's MagicDNS name: headscale's base_domain, read off the host that
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
    # The VM is a tailnet node of its own, which its host answers for
    # (./_host.nix: ark.tailnet.guests).
    includes = [ config.den.aspects.tailnet ];

    secrets = {
      # The VM's Signal identity, saved by `ark service sivrad signal ...`
      # after registering, so a rebuilt VM comes back as the same
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
        inputs.microvm.nixosModules.host
        ./_host.nix
        (import ./_kanidm.nix {
          origin = idOrigin;
          members = lib.attrNames people;
        })
      ];
      assertions = [
        {
          assertion = notE164 == [ ];
          message = "ark.persons.<name>.signal must be E.164 (+ and the country code, digits only, e.g. +15551234567); not so for: ${lib.concatStringsSep ", " notE164}";
        }
        {
          assertion = shared == { };
          message = "ark.persons: a Signal number belongs to one person only; shared by: ${lib.concatStringsSep "; " (map (lib.concatStringsSep ", ") (lib.attrValues shared))}";
        }
      ];
      microvm.vms.sivrad.specialArgs = {
        # Who may use sivrad, for the channel's people.json (./_guest.nix):
        # { "<username>": { "signal": "+..." } }.
        people = lib.mapAttrs (_: p: { inherit (p) signal; }) people;
        # How a node joins the tailnet, shared with the hosts (den.aspects.tailnet).
        tailnet = config.flake.nixosModules.ark-tailnet;
        oidc = {
          issuer = "${idOrigin}/oauth2/openid/sivrad";
          clientId = "sivrad";
        };
      };
    };
  };

  # What `ark service sivrad ...` reads (cli/mod.rs), through `nix eval`.
  config.flake.arkServiceConfig.sivrad = {
    # ssh target: the VM's own tailnet node; null without headscale.
    host = if tailnetDomain == null then null else "${vm.name}.${tailnetDomain}";
    inherit (vm) user;
    signal = {
      configDir = vm.signalDir;
      socket = vm.signalSocket;
    };
    # Who may use sivrad (ark.persons with a Signal number), for `init`.
    people = lib.attrNames people;
  };
}
