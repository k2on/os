{ self, inputs, ... }: {
  flake.nixosModules.koonMaxHomeManager = { ... }: {
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

  flake.homeModules.koonMaxHome = { ... }: {
    imports = [
      self.homeModules.commonFeatureHyprlandConfig
      self.homeModules.commonFeatureHypridle
      self.homeModules.commonFeatureHyprlock
      self.homeModules.commonFeatureNotifications
      self.homeModules.commonFeatureOsd
      self.homeModules.commonFeatureWalker
      self.homeModules.commonFeatureWallpaper
      self.homeModules.commonFeatureWaybar

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

    home.username = "max";
    home.homeDirectory = "/home/max";
    home.stateVersion = "25.05";
  };
}
