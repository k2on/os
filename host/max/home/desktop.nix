{ lib, ... }: {
  programs.plasma = {
    enable = true;
    workspace = { wallpaper = "/home/max/bg.jpg"; };

    kwin = { virtualDesktops = { number = 4; }; };

    input = {
      keyboard = {
        options = [ "caps:escape" ];
        layouts = [ { layout = "us"; } { layout = "cn"; } ];
      };
    };
  };
}
