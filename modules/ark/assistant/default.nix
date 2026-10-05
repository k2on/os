{ inputs, config, ... }:
{
  den.aspects.assistant.nixos = {
    imports = [
      inputs.microvm.nixosModules.host
      ./host.nix
    ];
    # Same login server as den.aspects.tailnet.
    microvm.vms.assistant.specialArgs.loginServer =
      "https://${config.ark.serviceDomain "headscale" config.ark.services.headscale}";
  };
}
