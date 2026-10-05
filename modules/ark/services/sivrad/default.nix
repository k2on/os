# sivrad: a microVM on adam running an always-on Claude Code session, named
# after the owner's phone voice assistant it serves.
# Not an ark.services entry (no HTTP service behind nginx): it defines the
# Den aspect den.aspects.sivrad directly. Files starting with `_` carry the
# underscore so import-tree does not load them as flake modules.
{ inputs, config, ... }:
let
  ark = config.ark;
  # Kanidm's per-client issuer, as in lib/oidc.nix.
  idOrigin = "https://id.${ark.mainDomain}";
in
{
  den.aspects.sivrad = {
    # The identity table: who may talk to sivrad, entered by hand with
    # `ark secrets`. A JSON object keyed by Kanidm username, e.g.
    #   { "alice": { "signal": "+15551234567" }, "bob": { "signal": "+15557654321" } }
    # The host hands it to the guest as people.json (./_host.nix); the
    # channel re-reads it on every request, so edits apply without a restart.
    secrets.sivrad_people.restartUnits = [ "sivrad-credentials.service" ];

    nixos = {
      imports = [
        inputs.microvm.nixosModules.host
        ./_host.nix
        (import ./_kanidm.nix {
          origin = idOrigin;
          # secrets/ark.nix: ark.groups.sivrad.users = [ "<username>" ... ];
          members = ark.groups.sivrad.users or [ ];
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
}
