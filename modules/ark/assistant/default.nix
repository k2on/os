{ inputs, ... }:
{
  den.aspects.assistant.nixos = {
    imports = [
      inputs.microvm.nixosModules.host
      ./host.nix
    ];
  };
}
