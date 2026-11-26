# Max's home, wherever he signs in: den.aspects.max's homeManager, which
# each file here adds to. On a host that has him as a user
# (den.hosts.<…>.users.max) den puts it in that host's home-manager; on its
# own it is homeConfigurations.max (`home-manager switch --flake .#max`),
# checked by `nix flake check` on aarch64-linux, where it runs. A desktop's
# share of every home (the browser, mail, terminal emulator, wallpaper) is
# aspects/gui/home's.
{ self, den, ... }:
{
  den.homes.aarch64-linux.max = { };

  # His terminal, music and Codex (with its key-holding proxy on the host he
  # uses).
  den.aspects.max.includes = with den.aspects; [
    terminal
    codex
  ];

  perSystem =
    { lib, system, ... }:
    {
      checks = lib.optionalAttrs (system == "aarch64-linux") {
        home-max = self.homeConfigurations.max.activationPackage;
      };
    };

  den.aspects.max.homeManager =
    { lib, ... }:
    {
      imports = [ self.homeModules.arkCli ];

      # The home's own nixpkgs settings, the same on a host and on its own.
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

      home.username = "max";
      home.homeDirectory = "/home/max";
      home.stateVersion = "25.05";
    };
}
