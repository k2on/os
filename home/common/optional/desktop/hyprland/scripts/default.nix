{ pkgs }:
{
  lock =
    pkgs.writeShellScript "koonos-lock-screen" ''
      ${pkgs.hyprlock}/bin/hyprlock
    '';
}
