# The desktop: COSMIC, signed in to through its greeter.
{ ... }:
{
  den.aspects.gui.nixos =
    { pkgs, ... }:
    {
      services.desktopManager.cosmic.enable = true;
      services.displayManager.cosmic-greeter = {
        enable = true;
        # Its list of people only has the accounts the system enumerates,
        # with UIDs up to UID_MAX: Kanidm's are neither (./login.nix), so
        # nobody signing in through Kanidm would be listed. Patched to also
        # list whoever has a home under /home, someone who has signed in
        # here before. Drop it once upstream lists such accounts itself.
        package = pkgs.cosmic-greeter.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./cosmic-greeter-home-users.patch ];
        });
      };
      environment.sessionVariables.NIXOS_OZONE_WL = "1";
    };
}
