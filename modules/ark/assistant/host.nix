# Host side of the `assistant` microVM: a tap link to the guest plus NAT.
# The guest itself is described in ./guest.nix.
{ ... }:
let
  tap = "vm-assistant";
  hostAddress = "192.168.77.1";
in
{
  microvm.vms.assistant = {
    # Rebuilding adam must not kill a running conversation; restart the VM
    # by hand (`systemctl restart microvm@assistant`) to pick up changes.
    restartIfChanged = false;
    # Build the guest from its own nixpkgs instance so the claude-code
    # unfree allowance stays scoped to the VM (see guest.nix).
    pkgs = null;
    config.imports = [ ./guest.nix ];
  };

  # The tap device is created by microvm-tap-interfaces@assistant.service;
  # scripted networking binds network-addresses-vm-assistant.service to the
  # device, so the address is (re)applied whenever the tap (re)appears.
  networking.interfaces.${tap}.ipv4.addresses = [
    {
      address = hostAddress;
      prefixLength = 24;
    }
  ];

  # No externalInterface: masquerade on whichever interface the route picks.
  networking.nat = {
    enable = true;
    internalInterfaces = [ tap ];
  };
}
