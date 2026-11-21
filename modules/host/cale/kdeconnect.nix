{ ... }:
{
  # KDE Connect finds devices by UDP broadcast, which stays on the LAN:
  # over Tailscale it has to be told where the phone is. Its config is also
  # its own state (it writes the name and providers there), so the address
  # is set into it rather than the file replaced. Headscale keeps a node's
  # address, so it holds.
  flake.homeModules.koonMaxKdeConnect =
    { lib, pkgs, ... }:
    let
      devices = [
        "100.64.0.2" # pixel-8
      ];
    in
    {
      home.activation.kdeconnectDevices = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$HOME/.config/kdeconnect/config" --group General \
          --key customDevices ${lib.escapeShellArg (lib.concatStringsSep "," devices)}
      '';
    };
}
