# Max's browser tabs: a Personal container and space, with Proton Mail and
# Money pinned. The browser itself is every desktop's (aspects/gui/home).
{ config, ... }:
{
  den.aspects.max.homeManager =
    let
      containers = {
        Personal = {
          color = "yellow";
          icon = "circle";
          id = 1;
        };
      };
      spaces = {
        Personal = {
          id = "c6de089c-410d-4206-961d-ab11f988d40a";
          icon = "⭐";
          container = containers."Personal".id;
          position = 1000;
        };
      };
      pins = {
        "Money" = {
          id = "10cb5609-fcd5-4ed6-a48d-24eb22f2d624";
          container = containers.Personal.id;
          url = "https://money.${config.ark.mainDomain}";
          isEssential = true;
          position = 1;
        };
      };
    in
    {
      programs.zen-browser.profiles.default = {
        containersForce = true;
        spacesForce = true;
        pinsForce = true;
        inherit containers spaces pins;
      };
    };
}
