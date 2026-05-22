{ self, ... }: {
  flake.homeModules.commonFeatureWallpaper = { ... }:
    let
      wallpaper = builtins.toString "${self}/assets/wallpaper.jpg";
    in {
    services.hyprpaper = {
      enable = true;
      settings = {
        spash = false;

        preload = [ wallpaper ];

        wallpaper = [
          "eDP-1,${wallpaper}"
          "HDMI-A-1,${wallpaper}"
        ];
      };
    };
  };
}

