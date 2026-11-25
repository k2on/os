# The tailnet on a desktop: Tailscale pointed at headscale, signed in as the
# person using it (`tailscale up` and the browser, once), not as the host
# (aspects/defaults/tailnet.nix) — so the node is theirs, and the tailnet's
# rules for them apply. Its interface is trusted, for the phone (KDE Connect)
# and the rest of their own devices.
{ config, ... }:
{
  den.aspects.gui.nixos =
    { pkgs, ... }:
    {
      services.tailscale = {
        enable = true;
        extraUpFlags = [ "--login-server=https://vpn.${config.ark.mainDomain}" ];
      };

      networking.firewall.trustedInterfaces = [ "tailscale0" ];

      systemd.services.tailscale-restart = {
        description = "Restart Tailscale after waking up";
        after = [ "suspend.target" ];
        wantedBy = [ "suspend.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.systemd}/bin/systemctl restart tailscaled.service";
        };
      };
    };
}
