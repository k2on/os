{ ... }: {
  flake.homeModules.commonFeatureOsd = { ... }: {
    services.swayosd = {
      enable = true;
    };

    home.file.".config/swayosd/style.css".source = ./swayosd/style.css;
  };
}
