# The desktop's look: dark GTK, and ark's wallpaper on COSMIC.
{ ... }:
{
  den.aspects.gui.provides.home.homeManager = {
    gtk = {
      enable = true;
      colorScheme = "dark";
    };

    # cosmic-bg reads per-key RON files under this component directory; with
    # `same-on-all` enabled it applies the `all` entry to every output.
    xdg.configFile = {
      "cosmic/com.system76.CosmicBackground/v1/same-on-all".text = "true";
      "cosmic/com.system76.CosmicBackground/v1/all".text = ''
        (
            output: "all",
            source: Path("${../../../../assets/wallpaper.jpg}"),
            filter_by_theme: false,
            rotation_frequency: 300,
            filter_method: Lanczos,
            scaling_mode: Zoom,
            sampling_method: Alphanumeric,
        )
      '';
    };
  };
}
