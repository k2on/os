{ ... }:
{
  flake.nixosModules.kanidm = { pkgs, ... }: {
  # ark.services.id = { service, pkgs, ... }: {
    services.kanidm = {
      package = pkgs.kanidmWithSecretProvisioning_1_10;
      server = {
        enable = true;
        settings = {
          domain = "id.koon.us";
          origin = "https://id.koon.us";
          bindaddress = "0.0.0.0:443";

          tls_chain = "/var/lib/acme/koon.us/fullchain.pem";
          tls_key = "/var/lib/acme/koon.us/key.pem";

        };
      };

      client = {
        enable = true;
        settings.uri = "https://id.koon.us";
      };

      provision = {
        enable = true;
      };
    };

    systemd.services.kanidm = {
      wants = [ "acme-finished-koon.us.target" ];
      after = [ "acme-finished-koon.us.target" ];
    };

    systemd.services.kanidm.serviceConfig.ExecReload = "/run/current-system/sw/bin/kill -HUP $MAINPID";
  };
}
