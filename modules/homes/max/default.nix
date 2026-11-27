# Max's own part of his home (homes/default.nix makes the home itself,
# homeConfigurations.max-<system>): den.aspects.max's homeManager, which each file
# here adds to. A desktop's share of every home (the browser, mail, terminal
# emulator, wallpaper) is aspects/gui/home's.
{ self, den, ... }:
{
  # His terminal (Codex in it).
  den.aspects.max.includes = with den.aspects; [ terminal ];

  den.aspects.max.homeManager =
    { lib, ... }:
    {
      imports = [ self.homeModules.arkCli ];

      nixpkgs = {
        overlays = [ self.overlays.unstable ];
        # Chromium with Widevine (./apps.nix), and transparent.nvim (neovim),
        # which ships no license file, so nixpkgs marks it unfree as of 26.05.
        config.allowUnfreePredicate =
          pkg:
          builtins.elem (lib.getName pkg) [
            "chromium"
            "chromium-unwrapped"
            "widevine-cdm"
            "transparent.nvim"
          ];
      };

      home.stateVersion = "25.05";
    };
}
