# Wi-Fi, battery and power state, and the clock following you.
{ ... }:
{
  den.aspects.gui.nixos = {
    networking.networkmanager.enable = true;
    services.upower.enable = true;
    services.automatic-timezoned.enable = true;
  };
}
