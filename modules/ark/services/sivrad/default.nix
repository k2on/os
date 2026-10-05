# sivrad: a microVM on adam running an always-on Claude Code session, named
# after the owner's phone voice assistant it serves.
# Not an ark.services entry (no HTTP service behind nginx): it defines the
# Den aspect den.aspects.sivrad directly. Files starting with `_` carry the
# underscore so import-tree does not load them as flake modules.
#
# Set up from a laptop with `ark service sivrad ...` (./cli/mod.rs), which
# drives the VM over ssh and keeps everything durable in the secrets repo:
#
#   ark service sivrad init                  # people, the Claude login, and
#                                            # what is still missing
#   ark service sivrad people add alice +15551234567
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
  options.ark.sivrad.people = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "alice" ];
    description = ''
      Kanidm usernames in the sivrad_users group, who may sign in to the
      sivrad app. Written to secrets/services/sivrad/people.nix by
      `ark service sivrad people ...` from the sivrad_people secret, so the
      two stay in step.
    '';
  };

  config.den.aspects.sivrad = {
    secrets = {
      # The identity table: who may talk to sivrad. A JSON object keyed by
      # Kanidm username, e.g.
      #   { "alice": { "signal": "+15551234567" }, "bob": { "signal": "+15557654321" } }
      # kept by `ark service sivrad people`. The host hands it to the guest as
      # people.json (./_host.nix); the channel re-reads it on every request,
      # so edits apply without a restart.
      sivrad_people.restartUnits = [ "sivrad-credentials.service" ];

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
          members = ark.sivrad.people;
        })
      ];
      microvm.vms.sivrad.specialArgs = {
        # Same login server as den.aspects.tailnet.
        loginServer = "https://${ark.serviceDomain "headscale" ark.services.headscale}";
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
    # Who has a Kanidm account (secrets/ark.nix), since only they can join
    # the sivrad_users group.
    persons = lib.attrNames ark.persons;
  };
}
