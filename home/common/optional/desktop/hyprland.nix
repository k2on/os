{ pkgs, pkgs-unstable, ... }:
let
  scripts = import ./hyprland/scripts/default.nix { inherit pkgs; };
in
{
  imports = [
    (import ./hyprland/hyprland.nix { inherit pkgs scripts pkgs-unstable; })
    (import ./hyprland/wallpaper.nix { inherit pkgs scripts; })
    (import ./hyprland/hyprlock.nix { inherit pkgs scripts; })
    (import ./hyprland/hypridle.nix { inherit pkgs scripts; })
    ./hyprland/notifications.nix
  ];




}

