{ inputs, ... }: {
  imports = [
    inputs.den.flakeModule
    inputs.home-manager.flakeModules.home-manager
    inputs.disko.flakeModules.default
  ];

  config = {
    systems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}

