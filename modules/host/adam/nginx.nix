{ config, ... }:
let
  inherit (config.ark) mergeServices assignServicePorts serviceDomain;
in
{
  den.aspects.ark-nginx.nixos = { ark-service, lib, host, ... }:
    let
      services = mergeServices ark-service;
      ports = assignServicePorts services;
      serviceVhosts = lib.mapAttrs'
        (name: spec: lib.nameValuePair
          (serviceDomain name spec)
          {
            useACMEHost = config.ark.mainDomain;
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
            useACMEHost = config.ark.mainDomain;
            addSSL = true;
            locations."/".return = "404";
          };
        };
      };

      networking.firewall.allowedTCPPorts = [ 443 ]; # 80 too if you want HTTP→HTTPS redirects

      # nginx needs read access to the cert, which is group-owned by kanidm
      # TODO: FIXME
      users.users.nginx.extraGroups = [ "kanidm" ];
    };
}
