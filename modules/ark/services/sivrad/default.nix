# sivrad: a microVM on adam running an always-on Claude Code session, named
# after the owner's phone voice assistant it serves. An ark.services entry
# like any other (lib/services.nix): its Kanidm client, group, secrets,
# domain and nginx vhost come from the registry. Files starting with `_`
# carry the underscore so import-tree does not load them as flake modules.
#
# The phone signs in through a public OIDC client `sivrad` (PKCE, no client
# secret) that redirects to the app's custom scheme, and reaches the channel
# at https://sivrad.<mainDomain>, a private name on the tailnet: adam's
# nginx proxies it over the tap link to the channel in the VM (./_host.nix,
# ./_guest.nix). The channel checks the access token against the client's
# userinfo endpoint (./channel/src/oidc.rs).
#
# Who may use sivrad is the registry's convention, in secrets/ark.nix:
#
#   ark.groups.sivrad.users = [ "alice" "bob" ];
#   ark.persons.alice.signal = "+15551234567";   # optional
#
# The group's members make up the Kanidm group sivrad_users, which may sign
# in to the phone app, and the channel's people.json, which maps them to
# their Signal numbers (./_guest.nix). A member without a number uses the
# phone app only. There is no command for it: edit secrets/ark.nix, commit
# it and deploy adam, then restart the VM (`systemctl restart
# microvm@sivrad`) for the channel to see the change.
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
  # Who may use sivrad: the members of the Kanidm group sivrad_users.
  members = ark.groups.sivrad.users or [ ];
  # Their Signal numbers, null for a member without one. A member who is not
  # a person is left to Kanidm's provisioning to report.
  people = lib.genAttrs members (name: {
    signal = ark.persons.${name}.signal or null;
  });
  onSignal = lib.filterAttrs (_: p: p.signal != null) people;
  # E.164, as the channel and signal-cli expect: + and the country code.
  notE164 = lib.attrNames (
    lib.filterAttrs (_: p: builtins.match "[+][1-9][0-9]{6,14}" p.signal == null) onSignal
  );
  # The channel tells Signal senders apart by their number.
  shared = lib.filterAttrs (_: names: lib.length names > 1) (
    lib.groupBy (name: onSignal.${name}.signal) (lib.attrNames onSignal)
  );

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
  config.ark.services.sivrad = {
    oidc = {
      # The Android app: PKCE, no client secret.
      public = true;
      displayName = "Sivrad";
      callbacks = [ "sivrad://oauth/callback" ];
    };

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

    nixos =
      { service, lib, ... }:
      {
        imports = [
          inputs.microvm.nixosModules.host
          ./_host.nix
        ];
        assertions = [
          {
            assertion = notE164 == [ ];
            message = "ark.persons.<name>.signal must be E.164 (+ and the country code, digits only, e.g. +15551234567); not so for: ${lib.concatStringsSep ", " notE164}";
          }
          {
            assertion = shared == { };
            message = "ark.persons: a Signal number belongs to one sivrad user only; shared by: ${lib.concatStringsSep "; " (map (lib.concatStringsSep ", ") (lib.attrValues shared))}";
          }
        ];

        # The registry's vhost proxies to 127.0.0.1:<port>; the channel is in
        # the VM, across the tap. It holds a request for up to 120 s
        # (SIVRAD_TIMEOUT_MS) before answering, so nginx waits longer.
        services.nginx.virtualHosts.${service.domain}.locations."/" = {
          proxyPass = lib.mkForce "http://${vm.address}:${toString vm.channelPort}";
          extraConfig = ''
            proxy_read_timeout 150s;
            proxy_send_timeout 150s;
          '';
        };

        microvm.vms.sivrad.specialArgs = {
          # Who may use sivrad, for the channel's people.json (./_guest.nix):
          # { "<username>": { "signal": "+..." | null } }.
          inherit people;
          # Same login server as den.aspects.tailnet.
          loginServer = "https://${ark.serviceDomain "headscale" ark.services.headscale}";
          oidc = { inherit (service.oidc) issuer clientId; };
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
    # Who may use sivrad (ark.groups.sivrad.users), for `init`.
    people = members;
    # Where the phone app reaches the channel.
    domain = ark.serviceDomain "sivrad" ark.services.sivrad;
  };
}
