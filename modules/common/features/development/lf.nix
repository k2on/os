{ ... }: {
  flake.homeModules.commonFeatureLf = { ... }: {
    programs.lf = { enable = true; };
  };
}
