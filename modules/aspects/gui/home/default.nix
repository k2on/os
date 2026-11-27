# What every person's home gets on a desktop: the browser, their mail,
# contacts and calendars, a terminal emulator (Alacritty), PDF and image
# viewers, the wallpaper. Each file here adds to
# den.aspects.gui.provides.home's homeManager; their own taste is their own
# aspect's (homes/<person>). Homes are people's (homeConfigurations.<person>-<system>,
# homes/default.nix), which a desktop activates as they sign in
# (aspects/gui/homes.nix).
{ den, ... }:
{
  den.schema.home.includes = [ den.aspects.gui.provides.home ];
}
