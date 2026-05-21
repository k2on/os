{ ... }: {
  flake.homeModules.commonFeatureWalker = { ... }: {
    home.file.".config/walker/config.toml".source = ./walker/config.toml;
  };
}
