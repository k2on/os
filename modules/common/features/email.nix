{ ... }: {
  flake.nixosModules.commonFeatureEmail = { ... }: {
    programs.thunderbird.enable = true;
  };
}

