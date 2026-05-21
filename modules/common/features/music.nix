{ ... }: {
  flake.homeModules.commonFeatureMusic = { pkgs, ... }: {
    home.packages = with pkgs; [
      mpc
    ];

    services.mpd = {
      enable = true;
      musicDirectory = "/home/max/media/music";

      # extraConfig = ''
      #   audio_output {
      #     type "pipewire"
      #     name "pipewire"
      #   }
      # '';


      extraConfig = ''
        audio_output {
          type "alsa"
          name "My ALSA"
          mixer_type		"hardware"
          mixer_device	"default"
          mixer_control	"PCM"
        }
      '';

    };

    services.mpd-mpris.enable = true;

    programs.ncmpcpp = {
      enable = true;
      bindings = [
        { key = "j"; command = "scroll_down"; }
        { key = "k"; command = "scroll_up"; }
        { key = "h"; command = "previous_column"; }
        { key = "l"; command = "next_column"; }

        { key = "J"; command = [ "select_item" "scroll_down" ]; }
        { key = "K"; command = [ "select_item" "scroll_up" ]; }
      ];
    };
  };
}

