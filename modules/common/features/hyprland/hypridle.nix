{ ... }: {
  flake.homeModules.commonFeatureHypridle = { pkgs, ... }: {
    services.hypridle = {
      enable = true;

      settings = {
        general = {
            lock_cmd = "${pkgs.hyprlock}/bin/hyprlock";
            before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";               # lock before suspend.
            after_sleep_cmd = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";             # to avoid having to press a key twice to turn on the display.
            inhibit_sleep = 3;                                      # wait until screen is locked
        };

        listener = [
          {
              timeout = 60 * 5;                      # 5min
              on-timeout = "${pkgs.systemd}/bin/loginctl lock-session"; # lock screen when timeout has passed
          }
          {
              timeout = 60 * 5.5;                                            # 5.5min
              on-timeout = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off";                   # screen off when timeout has passed
              on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on && brightnessctl -r"; # screen on when activity is detected
          }
        ];
      };
    };
  };
}

