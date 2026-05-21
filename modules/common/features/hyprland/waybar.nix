{ ... }: {
  flake.homeModules.commonFeatureWaybar = { ... }: {
    home.file.".config/waybar/config.jsonc".source = ./waybar/config.jsonc;
    home.file.".config/waybar/style.css".source = ./waybar/style.css;
  };
}
