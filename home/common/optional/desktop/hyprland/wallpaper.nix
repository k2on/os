{ ... }:
{
  services.hyprpaper = {
    enable = true;
    settings = {
      spash = false;

      preload = ["~/Downloads/wallpaper.png"];

      wallpaper = [
        "eDP-1,~/Downloads/wallpaper.png"
        "HDMI-A-1,~/Downloads/wallpaper.png"
      ];
    };
  };
}
