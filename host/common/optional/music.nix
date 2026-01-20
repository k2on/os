{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    mpc
    ncmpcpp
  ];

  services.mpd = {
    enable = true;
    musicDirectory = "/home/max/media/music";
    user = "max";
    extraConfig = ''
      audio_output {
        type "pipewire"
        name "Pipewire Ouput"
      }
    '';
  };

  systemd = {
    services = {
      mpd.environment = {
        XDG_RUNTIME_DIR = "/run/user/1001";
      };
    };
  };
}
