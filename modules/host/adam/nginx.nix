{ config, ... }:
let
  inherit (config.ark) mergeServices assignServicePorts serviceDomain;
in
{
  den.aspects.ark-nginx.nixos =
    {
      ark-service,
      lib,
      host,
      ...
    }:
    let
      services = mergeServices ark-service;
      ports = assignServicePorts services;
      serviceVhosts = lib.mapAttrs' (
        name: spec:
        lib.nameValuePair (serviceDomain name spec) {
          useACMEHost = config.ark.mainDomain;
          forceSSL = true;
          locations."/" = {
            # `127.0.0.1`, not `localhost`: nginx resolves the latter to `[::1]`
            # as well, and every service here binds v4 — so one request in a
            # few landed on an address nothing answers on and was a 502. GETs
            # were retried on the other address and hid it; POSTs are not
            # retried, which is how harken's calls to Home Assistant went
            # missing.
            proxyPass = "http://127.0.0.1:${toString ports.${name}}";
            proxyWebsockets = true;
          };
        }
      ) services;
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
