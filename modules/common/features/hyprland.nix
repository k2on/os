{ self, inputs, ... }: {
  flake.nixosModules.commonFeatureHyprland = { pkgs, ... }: {
    programs.hyprland = {
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };

    systemd.services.greetd.serviceConfig = {
      Type = "idle";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "journal"; # Without this errors will spam on screen
      # Without these bootlogs will spam on screen
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
    };

    services.greetd = {
      enable = true;
      settings = {
        default_session = {
          command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd 'uwsm start hyprland-uwsm.desktop'";
          user = "greeter";
        };
      };
    };

    security.pam.services.hyprlock = {};

    programs.ydotool.enable = true;

    environment.systemPackages = with pkgs; [
      hyprpaper
      hypridle
      hyprpicker
      hyprsunset
      hyprshot
      waybar
      walker
      swayosd

      playerctl
      brightnessctl
      wl-clipboard
      wdisplays

      bluetui

      kdePackages.dolphin
    ];
  };
}
