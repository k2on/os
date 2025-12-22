{ pkgs, ... }:
{
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
}
