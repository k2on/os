{ ... }:
{
  imports = [
    ./hyprland/font.nix
    ./hyprland/cursor.nix
    ./hyprland/packages.nix
    ./hyprland/greeter.nix
    ./hyprland/hyprlock.nix
  ];

  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
  };
}
