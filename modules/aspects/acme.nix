{ lib, config, ... }:
let
  ark = config.ark;
  # Names two or more labels under mainDomain (browser.sivrad.<mainDomain>),
  # which the wildcard does not cover: they go on the certificate by name.
  # The DNS challenge works for them all the same, in mainDomain's zone.
  under = lib.removeSuffix ".${ark.mainDomain}";
  deepNames = lib.filter (d: d != under d && lib.hasInfix "." (under d)) (
    lib.concatLists (lib.attrValues ark.serviceDomains) ++ lib.attrNames ark.publicDomains
  );
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
          extraDomainNames = [ ark.mainDomain ] ++ lib.unique deepNames;

          dnsProvider = "cloudflare";
          environmentFile = config.sops.templates."cloudflare-acme.env".path;

          dnsResolver = "1.1.1.1:53";

          group = "kanidm";

          reloadServices = [ "kanidm.service" ];
        };
      };
    };
}
