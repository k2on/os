{
  perSystem.treefmt.programs = {
    nixfmt = {
      enable = true;
      excludes = [
        "infra/"
        "**/_hardware-configuration.nix"
      ];
    };
  };
}
