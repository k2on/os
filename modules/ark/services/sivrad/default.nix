# sivrad: a microVM on adam running an always-on Claude Code session, named
# after the owner's phone voice assistant it serves.
# Not an ark.services entry (no HTTP service behind nginx): it defines the
# Den aspect den.aspects.sivrad directly. _host.nix and _guest.nix carry the
# underscore so import-tree does not load them as flake modules.
{ inputs, config, ... }:
{
  den.aspects.sivrad.nixos = {
    imports = [
      inputs.microvm.nixosModules.host
      ./_host.nix
    ];
    # Same login server as den.aspects.tailnet.
    microvm.vms.sivrad.specialArgs.loginServer =
      "https://${config.ark.serviceDomain "headscale" config.ark.services.headscale}";
  };
}
