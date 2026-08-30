{ self, inputs, ... }:
{
  flake.nixosModules.koonMaxHomeManager =
    { ... }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
      ];

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = { inherit inputs self; };

        users.max = {
          imports = [ self.homeModules.koonMaxHome ];
        };
      };
    };

  flake.homeModules.koonMaxHome =
    { ... }:
    {
      imports = [
        self.homeModules.commonFeatureZathura
        self.homeModules.commonFeatureAlacritty
        self.homeModules.commonFeatureLf
        self.homeModules.commonFeatureTmux
        self.homeModules.commonFeatureStarship
        self.homeModules.commonFeatureDirenv
        self.homeModules.commonFeatureImageViewer
        self.homeModules.commonFeatureMusic
        self.homeModules.commonFeatureZsh

        self.homeModules.koonMaxBrowser
        self.homeModules.koonMaxNeovim
        self.homeModules.koonMaxGit
        self.homeModules.koonMaxSsh
      ];

      gtk = {
        enable = true;
        colorScheme = "dark";
      };

      # Declaratively set the COSMIC desktop wallpaper from the repo assets.
      # cosmic-bg reads per-key RON files under this component directory; with
      # `same-on-all` enabled it applies the `all` entry to every output.
      xdg.configFile = {
        "cosmic/com.system76.CosmicBackground/v1/same-on-all".text = "true";
        "cosmic/com.system76.CosmicBackground/v1/all".text = ''
          (
              output: "all",
              source: Path("${../../../assets/wallpaper.jpg}"),
              filter_by_theme: false,
              rotation_frequency: 300,
              filter_method: Lanczos,
              scaling_mode: Zoom,
              sampling_method: Alphanumeric,
          )
        '';
      };

      home.username = "max";
      home.homeDirectory = "/home/max";
      home.stateVersion = "25.05";
    };
}
