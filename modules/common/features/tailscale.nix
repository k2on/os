{ config, ... }:
{
  flake.nixosModules.koonFeatureTailscale =
    { pkgs, ... }:
    {
      services.tailscale = {
        enable = true;
        extraUpFlags = [ "--login-server=https://vpn.${config.ark.mainDomain}" ];
      };

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
