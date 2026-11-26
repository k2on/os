# What every person's home gets on a desktop: the browser, their mail,
# contacts and calendars, a terminal emulator (Alacritty), PDF and image
# viewers, the wallpaper. Each file here adds to
# den.aspects.gui.provides.home's homeManager; their own taste is their own
# aspect's (homes/<person>).
{ den, ... }:
{
  # A host's users, where the host is a desktop (has the gui aspect).
  den.schema.user.includes = [
    (den.lib.policy.when ({ host, ... }: host.hasAspect den.aspects.gui) den.aspects.gui.provides.home)
  ];
  # And a home on its own (homeConfigurations.<person>): those are people's,
  # for their desktops.
  den.schema.home.includes = [ den.aspects.gui.provides.home ];
}
