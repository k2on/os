# People's homes on a desktop (homes/default.nix makes them): built only
# for whoever signs in, not for everyone who could.
#
# The system carries every home's recipe, unbuilt: /etc/ark/homes/<person>
# is its .drv, a few small files, which comin's evaluation already made. As
# someone signs in, ark-home (a service of theirs) builds their own,
# downloading what a cache has and building the rest, keeps it from garbage
# collection, and activates it. After a deploy it runs again for whoever is
# signed in, so their home follows main as the system does.
{ config, ... }:
let
  homes = config.flake.homeConfigurations or { };
in
{
  den.aspects.gui.nixos =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      # This platform's homes. The recipe alone: the .drv without its output,
      # so the system does not build or download any home.
      recipes = lib.filterAttrs (_: h: h.pkgs.stdenv.hostPlatform.system == system) homes;

      ark-home = pkgs.writeShellApplication {
        name = "ark-home";
        runtimeInputs = [
          config.nix.package
          pkgs.coreutils
        ];
        text = ''
          recipe=/etc/ark/homes/$USER
          if [ ! -e "$recipe" ]; then
            echo "No home for $USER on this desktop."
            exit 0
          fi
          drv=$(readlink -f "$recipe")
          state=''${XDG_STATE_HOME:-$HOME/.local/state}/ark
          mkdir -p "$state"

          if [ -e "$state/home" ] && [ "$(readlink "$state/home.drv" || true)" = "$drv" ]; then
            echo "Home is up to date."
            exit 0
          fi

          echo "Building $USER's home: $drv"
          # $state/home is a garbage collector root for it.
          home=$(nix-store --realise "$drv" --add-root "$state/home")
          "$home/activate"
          ln -sfn "$drv" "$state/home.drv"
        '';
      };
    in
    {
      environment.etc = lib.mapAttrs' (
        _: h:
        lib.nameValuePair "ark/homes/${h.config.home.username}" {
          source = builtins.unsafeDiscardOutputDependency h.activationPackage.drvPath;
        }
      ) recipes;

      environment.systemPackages = [ ark-home ];

      systemd.user.services.ark-home = {
        description = "Build and activate this person's home";
        wantedBy = [ "default.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe ark-home;
          # A first build, with nothing cached, takes a while.
          TimeoutStartSec = "30min";
        };
      };

      # After a deploy, NixOS runs these for everyone signed in: a new home of
      # theirs is built and activated then. At sign-in it runs once ark-home
      # has, and finds the home up to date.
      system.userActivationScripts.ark-home = ''
        if [ -e "/etc/ark/homes/$USER" ]; then
          ${config.systemd.package}/bin/systemctl --user restart --no-block ark-home.service
        fi
      '';
      systemd.user.services.nixos-activation.after = [ "ark-home.service" ];
    };
}
