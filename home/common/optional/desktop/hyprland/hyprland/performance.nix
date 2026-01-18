{ pkgs, lib, ... }:
let
  normal = {
    decoration = {
      blur.enabled = true;
      shadow.enabled = true;
    };
    misc.vfr = false;
  };
  battery-saver = {
    decoration = {
      blur.enabled = false;
      shadow.enabled = false;
    };
    misc.vfr = true;
  };

  normal-file = pkgs.writeText "hyprland.conf.normal" (lib.hm.generators.toHyprconf { attrs = normal; });
  battery-saver-file = pkgs.writeText "hyprland.conf.battery" (lib.hm.generators.toHyprconf { attrs = battery-saver; });

  switchScript = pkgs.writeShellScriptBin "switch-config" ''
    TARGET="$HOME/.config/koonos/current/performance/hyprland.conf"

    if [ "$(readlink "$TARGET")" = "${normal-file}" ]; then
      ln -sf ${battery-saver-file} "$TARGET"
      echo "Switched to battery saver"
    else
      ln -sf ${normal-file} "$TARGET"
      echo "Switched to normal mode"
    fi
  '';
in
{
  home.file.".config/koonos/current/performance/hyprland.conf".source = normal-file;

  home.packages = [ switchScript ];
}
