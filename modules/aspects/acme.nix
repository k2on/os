{ ... }:
{
  flake.nixosModules.acme = { config, ... }: {
    sops.templates."cloudflare-acme.env".content = ''
      CLOUDFLARE_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-api-key}
    '';

    security.acme = {
      acceptTerms = true;
      defaults.email = "contact@koon.us";

      certs."koon.us" = {
        domain = "*.koon.us";
        extraDomainNames = [ "koon.us" ];

        dnsProvider = "cloudflare";
        environmentFile = config.sops.templates."cloudflare-acme.env".path;
        # environmentFile = config.sops.secrets.cloudflare-api-key.path;

        dnsResolver = "1.1.1.1:53";

        group = "kanidm";

        reloadServices = [ "kanidm.service" ];
      };
    };
  };
}
