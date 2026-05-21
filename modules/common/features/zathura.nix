{ ... }: {
  flake.homeModules.commonFeatureZathura = { ... }: {
    programs.zathura = {
      enable = true;
      options = {
        selection-clipboard = "clipboard";
      };
    };
  };
}
