{ pkgs, ... }:
let
  scripts = import ./hyprland/scripts/default.nix { inherit pkgs; };
in
{
  imports = [
    (import ./hyprland/hyprland.nix { inherit pkgs scripts; })
    (import ./hyprland/wallpaper.nix { inherit pkgs scripts; })
    (import ./hyprland/hyprlock.nix { inherit pkgs scripts; })
    (import ./hyprland/hypridle.nix { inherit pkgs scripts; })
  ];

  home.file.".config/waybar/config.jsonc".source = ./hyprland/waybar/config.jsonc;
  home.file.".config/waybar/style.css".source = ./hyprland/waybar/style.css;

  services.swayosd = {
    enable = true;
  };

  home.file.".config/swayosd/style.css".source = ./hyprland/swayosd/style.css;

  home.file.".config/walker/config.toml".source = ./hyprland/walker/config.toml;
}

