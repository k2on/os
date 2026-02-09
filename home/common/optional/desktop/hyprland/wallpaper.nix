{ ... }:
let
  wallpaper = builtins.toString ../../../../../assets/wallpaper.jpg;
in
{
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
}
