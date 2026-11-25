# The desktop: COSMIC, signed in to through its greeter.
{ ... }:
{
  den.aspects.gui.nixos = {
    services.desktopManager.cosmic.enable = true;
    services.displayManager.cosmic-greeter.enable = true;
    environment.sessionVariables.NIXOS_OZONE_WL = "1";
  };
}
