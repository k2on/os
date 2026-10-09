{ config, ... }:
let
  ark = config.ark;
in
{
  flake.nixosModules.acme =
    { config, ... }:
    {
      sops.templates."cloudflare-acme.env".content = ''
        CLOUDFLARE_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-api-key}
      '';

      security.acme = {
        acceptTerms = true;
        defaults.email = "contact@${ark.mainDomain}";

        certs."${ark.mainDomain}" = {
          domain = "*.${ark.mainDomain}";
          extraDomainNames = [ ark.mainDomain ];

          dnsProvider = "cloudflare";
          environmentFile = config.sops.templates."cloudflare-acme.env".path;

          dnsResolver = "1.1.1.1:53";

          group = "kanidm";

          reloadServices = [ "kanidm.service" ];
        };
      };
    };
}
