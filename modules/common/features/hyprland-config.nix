{ ... }: {
  flake.homeModules.commonFeatureHyprlandConfig = { pkgs, ... }: {
    wayland.windowManager.hyprland = {
      enable = true;
      systemd.enable = false;

      plugins = with pkgs; [
        (hyprlandPlugins.mkHyprlandPlugin {
          pluginName = "hyprselect";
          version = "0.1";
          src = fetchFromGitHub {
            owner = "jmanc3";
            repo = "hyprselect";
            rev = "f9651b5fd64c730ee164a6fee6a08d0398dcbe0a";
            hash = "sha256-tY8EdfsjlUOuQ9v/POqpyLlkRO5wqEVSE9UeHfXuaGk=";
          };

          inherit (hyprland) nativeBuildInputs;

          meta = with lib; {
            homepage = "https://github.com/jmanc3/hyprselect";
            description = "A plugin that adds a completely useless desktop selection box to Hyprland";
            license = licenses.unlicense;
            platforms = platforms.linux;
          };
        })
        hyprlandPlugins.hyprscrolling
        # hyprlandPlugins.hyprbars
      ];

      settings = {
        # source = [
        #   "~/.config/koonos/current/performance/hyprland.conf"
        # ];

        "$terminal" = "${pkgs.uwsm}/bin/uwsm-app -- ${pkgs.alacritty}/bin/alacritty";
        "$fileManager" = "${pkgs.uwsm}/bin/uwsm-app -- ${pkgs.pcmanfm}/bin/pcmanfm";
        "$browser" = "${pkgs.uwsm}/bin/uwsm-app -- zen-beta";
        "$menu" = "${pkgs.walker}/bin/walker";
        "$player" = "${pkgs.playerctl}/bin/playerctl";

        monitor = [
          "eDP-1,preferred,1721x1080,auto"
          "HDMI-A-1,preferred,1450x0,auto"
        ];

        exec-once = [
          "${pkgs.uwsm}/bin/uwsm-app -- ${pkgs.hypridle}/bin/hypridle"
          "${pkgs.uwsm}/bin/uwsm-app -- ${pkgs.waybar}/bin/waybar"
          "${pkgs.uwsm}/bin/uwsm-app -- ${pkgs.hyprpaper}/bin/hyprpaper"
          "sleep 2 && pw-play --volume=0 ~/Downloads/empty.wav"
        ];

        env = [
          "HYPRCURSOR_THEME,macOS"
          "HYPRCURSOR_SIZE,20"
        ];

        # env = [
        #   "XCURSOR_SIZE,20"
        #   "XCURSOR_THEME,macOS"
        # ];

        general = {
          gaps_in = 0;
          gaps_out = 0;

          border_size = 2;

          "col.active_border" = "rgba(33ccffee) rgba(00ff99ee) 45deg";
          "col.inactive_border" = "rgba(595959aa)";

          # Set to true enable resizing windows by clicking and dragging on borders and gaps
          resize_on_border = true;

          # Please see https://wiki.hyprland.org/Configuring/Tearing/ before you turn this on
          allow_tearing = false;

          layout = "master";
        };

        decoration = {
          # rounding = 10
          # rounding_power = 2

          # Change transparency of focused and unfocused windows
          active_opacity = 1.0;
          inactive_opacity = 1.0;

          shadow = {
            # enabled = false;
            range = 4;
            render_power = 3;
            color = "rgba(1a1a1aee)";
          };

          # https://wiki.hyprland.org/Configuring/Variables/#blur
          blur = {
            # enabled = false;
            size = 3;
            passes = 1;

            vibrancy = 0.1696;
          };
        };


        # https://wiki.hyprland.org/Configuring/Variables/#animations
        animations = {
          enabled = true;

          # Default animations, see https://wiki.hyprland.org/Configuring/Animations/ for more
          bezier = [
            "easeOutQuint,0.23,1,0.32,1"
            "easeInOutCubic,0.65,0.05,0.36,1"
            "linear,0,0,1,1"
            "almostLinear,0.5,0.5,0.75,1.0"
            "quick,0.15,0,0.1,1"

          ];

          animation = [
            "global, 1, 10, default"
            "border, 0, 5.39, easeOutQuint"
            "windows, 1, 4.79, easeOutQuint"
            "windowsIn, 1, 4.1, easeOutQuint, popin 87%"
            "windowsOut, 1, 1.49, linear, popin 87%"
            "fadeIn, 1, 1.73, almostLinear"
            "fadeOut, 1, 1.46, almostLinear"
            "fade, 1, 3.03, quick"
            "layers, 1, 3.81, easeOutQuint"
            "layersIn, 1, 4, easeOutQuint, fade"
            "layersOut, 1, 1.5, linear, fade"
            "fadeLayersIn, 1, 1.79, almostLinear"
            "fadeLayersOut, 1, 1.39, almostLinear"
            "workspaces, 0, 1.94, almostLinear, fade"
            "workspacesIn, 0, 1.21, almostLinear, fade"
            "workspacesOut, 0, 1.94, almostLinear, fade"
          ];
        };


        dwindle = {
          pseudotile = true; # Master switch for pseudotiling. Enabling is bound to mainMod + P in the keybinds section below
          preserve_split = true; # You probably want this
        };

        # See https://wiki.hyprland.org/Configuring/Master-Layout/ for more
        master = {
          new_status = "master";
        };

        # https://wiki.hyprland.org/Configuring/Variables/#misc
        misc = {
          force_default_wallpaper = 0; # Set to 0 or 1 to disable the anime mascot wallpapers
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
        };


        #############
        ### INPUT ###
        #############

        # https://wiki.hyprland.org/Configuring/Variables/#input
        input = {
          kb_layout = "us";
          # kb_variant =
          # kb_model =
          kb_options = "caps:swapescape";
          # kb_rules =

          follow_mouse = 1;

          sensitivity = 0; # -1.0 - 1.0, 0 means no modification.
          repeat_rate = 35;
          repeat_delay = 300;

          touchpad = {
            natural_scroll = true;
            tap-to-click = false;
            clickfinger_behavior = true;
          };
        };

        # https://wiki.hyprland.org/Configuring/Variables/#gestures
        # gestures = {
        #   workspace_swipe = true;
        # };

        # See https://wiki.hyprland.org/Configuring/Keywords/
        "$mainMod" = "SUPER"; # Sets "Windows" key as main modifier
        bind = [

          # Example binds, see https://wiki.hyprland.org/Configuring/Binds/ for more
          "$mainMod, return, exec, $terminal"
          "$mainMod, W, killactive,"
          # bind = $mainMod, M, exit,
          "$mainMod, E, exec, $fileManager"
          "$mainMod, B, exec, $browser"

          # "$mainMod, M, exec, $terminal -e ${pkgs-unstable.gurk-rs}/bin/gurk"
          "$mainMod, P, exec, $terminal -e ${pkgs.ncmpcpp}/bin/ncmpcpp"
          "$mainMod SHIFT, B, exec, $terminal -e \"$EDITOR\" /home/max/bible.txt -R"
          "$mainMod SHIFT, R, exec, ${pkgs.hyprshot}/bin/hyprshot -m region --clipboard-only"

          # "$mainMod, V, togglefloating,"
          "$mainMod, space, exec, $menu"
          # "$mainMod, P, pseudo, # dwindle"
          "$mainMod, F, fullscreen"
          # bind = $mainMod, J, togglesplit, # dwindle

          "$mainMod SHIFT, Q, exec, ${pkgs.hyprlock}/bin/hyprlock"

          # Move focus with mainMod + arrow keys
          "$mainMod, H, movefocus, l"
          "$mainMod, L, movefocus, r"
          "$mainMod, K, movefocus, u"
          "$mainMod, J, movefocus, d"

          # Swap window with mainMod + shift + arrow keys
          "$mainMod SHIFT, H, swapwindow, l"
          "$mainMod SHIFT, L, swapwindow, r"
          "$mainMod SHIFT, K, swapwindow, u"
          "$mainMod SHIFT, J, swapwindow, d"

          # "$mainMod ALT, H, resizeactive, -40 0"
          # "$mainMod ALT, L, resizeactive, 40 0"

          # Switch workspaces with mainMod + [0-9]
          "$mainMod, 1, workspace, 1"
          "$mainMod, 2, workspace, 2"
          "$mainMod, 3, workspace, 3"
          "$mainMod, 4, workspace, 4"
          "$mainMod, 5, workspace, 5"
          "$mainMod, 6, workspace, 6"
          "$mainMod, 7, workspace, 7"
          "$mainMod, 8, workspace, 8"
          "$mainMod, 9, workspace, 9"
          "$mainMod, 0, workspace, 10"

          # Move active window to a workspace with mainMod + SHIFT + [0-9]
          "$mainMod SHIFT, 1, movetoworkspace, 1"
          "$mainMod SHIFT, 2, movetoworkspace, 2"
          "$mainMod SHIFT, 3, movetoworkspace, 3"
          "$mainMod SHIFT, 4, movetoworkspace, 4"
          "$mainMod SHIFT, 5, movetoworkspace, 5"
          "$mainMod SHIFT, 6, movetoworkspace, 6"
          "$mainMod SHIFT, 7, movetoworkspace, 7"
          "$mainMod SHIFT, 8, movetoworkspace, 8"
          "$mainMod SHIFT, 9, movetoworkspace, 9"
          "$mainMod SHIFT, 0, movetoworkspace, 10"

          # Example special workspace (scratchpad)
          "$mainMod, S, togglespecialworkspace, magic"
          "$mainMod SHIFT, S, movetoworkspace, special:magic"

          # Scroll through existing workspaces with mainMod + scroll
          # "$mainMod, mouse_down, workspace, e+1"
          # "$mainMod, mouse_up, workspace, e-1"

          ", Prior, exec, ${pkgs.ydotool}/bin/ydotool click --next-delay 0 0x40"
          ", Next, exec, ${pkgs.ydotool}/bin/ydotool click --next-delay 0 0x41"
        ];

        bindr = [
          ", Prior, exec, ${pkgs.ydotool}/bin/ydotool click --next-delay 0 0x80"
          ", Next, exec, ${pkgs.ydotool}/bin/ydotool click --next-delay 0 0x81"
        ];

        # Move/resize windows with mainMod + LMB/RMB and dragging
        bindm = [
          "$mainMod, mouse:272, movewindow"
          "$mainMod, mouse:273, resizewindow"
        ];

        "$osdclient" = "swayosd-client --monitor \"$(hyprctl monitors -j | ${pkgs.jq}/bin/jq -r '.[] | select(.focused == true).name')\"";

        bindel = [
          # Laptop multimedia keys for volume and LCD brightness
          # bindel = ,XF86AudioRaiseVolume, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
          # bindel = ,XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
          ",XF86AudioRaiseVolume, exec, $osdclient --output-volume=raise"
          ",XF86AudioLowerVolume, exec, $osdclient --output-volume=lower"
          ",XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
          ",XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
          # bindel = ,XF86MonBrightnessUp, exec, brightnessctl -e4 -n2 set 5%+
          # bindel = ,XF86MonBrightnessDown, exec, brightnessctl -e4 -n2 set 5%-
          ",XF86MonBrightnessUp, exec, $osdclient --brightness=raise"
          ",XF86MonBrightnessDown, exec, $osdclient --brightness=lower"
        ];

        bindl = [
          # Requires playerctl
          ", XF86AudioNext, exec, $player next"
          ", XF86AudioPause, exec, $player play-pause" ", XF86AudioPlay, exec, $player play-pause"
          ", XF86AudioPrev, exec, $player previous"
        ];

        bindd = [
          "$mainMod, C, Universal copy, sendshortcut, CTRL, Insert,"
          "$mainMod, V, Universal paste, sendshortcut, SHIFT, Insert,"
          "$mainMod, X, Universal cut, sendshortcut, CTRL, X,"
          "$mainMod, A, Universal select all, sendshortcut, CTRL, A,"
          "$mainMod, T, Universal new tab, sendshortcut, CTRL, T,"

          "$mainMod ALT, H, Universal left, sendshortcut, , Left,"
          "$mainMod ALT, J, Universal down, sendshortcut, , Down,"
          "$mainMod ALT, K, Universal up, sendshortcut, , Up,"
          "$mainMod ALT, L, Universal right, sendshortcut, , Right,"

          "$mainMod SHIFT ALT, H, Universal left, sendshortcut, SHIFT, Left,"
          "$mainMod SHIFT ALT, J, Universal down, sendshortcut, SHIFT, Down,"
          "$mainMod SHIFT ALT, K, Universal up, sendshortcut, SHIFT, Up,"
          "$mainMod SHIFT ALT, L, Universal right, sendshortcut, SHIFT, Right,"
        ];

        windowrule = [
          # Just dash of opacity by default
          "opacity 0.97 0.9, class:.*"

          # Ignore maximize requests from apps. You'll probably like this.
          "suppressevent maximize, class:.*"

          # Fix some dragging issues with XWayland
          "nofocus,class:^$,title:^$,xwayland:1,floating:1,fullscreen:0,pinned:0"
        ];

        plugin = {
          hyprselect = {
            "col.main" = "rgba(ffffff25)";
            "col.border" = "rgba(ffffff88)";

            fade_time_ms = 165.0;

            border_size = 1.0;
          };
          hyprscrolling = {
            fullscreen_on_one_column = true;
          };

          # hyprbars = {
          #   enabled = false;
          # };
        };
      };
    };

  };
}

