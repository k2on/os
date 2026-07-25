{ config, ... }:
let
  inherit (config.ark) mergeServices assignServicePorts serviceDomain;
in
{
  den.aspects.ark-nginx.nixos = { ark-service, config, lib, ... }:
    let
      services = mergeServices ark-service;
      ports = assignServicePorts services;
      serviceVhosts = lib.mapAttrs'
        (name: spec: lib.nameValuePair
          (serviceDomain name spec)
          {
            useACMEHost = "koon.us";
            forceSSL = true;
            locations."/" = {
              proxyPass = "http://localhost:${toString ports.${name}}";
              proxyWebsockets = true;
            };
          })
        services;
    in
    {
      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        recommendedGzipSettings = true;

        virtualHosts = serviceVhosts // {
          # equivalent of cloudflared's `default = "http_status:404"`
          "_" = {
            default = true;
            useACMEHost = "koon.us"; # so unknown *.koon.us names get a valid cert + 404
            addSSL = true;
            locations."/".return = "404";
          };

          # not (yet) registered as ark-services — kept verbatim:
          "media.koon.us" = {
            useACMEHost = "koon.us";
            forceSSL = true;
            locations."/" = {
              proxyPass = "http://localhost:8096"; # Jellyfin does not let you configure this
              proxyWebsockets = true;
            };
          };
        };
      };

      networking.firewall.allowedTCPPorts = [ 443 ]; # 80 too if you want HTTP→HTTPS redirects

      # nginx needs read access to the cert, which is group-owned by kanidm
      # TODO: FIXME
      users.users.nginx.extraGroups = [ "kanidm" ];
    };
}
