{ ... }:
{
  den.aspects.gui.provides.home.homeManager =
    { ... }:
    {
      programs.zathura = {
        enable = true;
        options = {
          selection-clipboard = "clipboard";
        };
      };
    };
}
