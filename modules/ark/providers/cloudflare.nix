{ config, ... }:
{
  den.aspects.provider-cloudflare.terranix =
    config.ark.dns.forProvider "cloudflare" ({ recordAttrs, providerDomains, lib, ... }:
    let zoneKey = d: lib.replaceStrings [ "." ] [ "_" ] d; in
    {
      terraform.required_providers.cloudflare = {
        source = "cloudflare/cloudflare";
        version = "~> 5.22.0";
      };
      provider.cloudflare = {};

      data.cloudflare_zone = builtins.listToAttrs (map (d: {
        name = zoneKey d.domain;
        value.filter.name = d.domain;
      }) providerDomains);

      resource.cloudflare_dns_record = recordAttrs (r: {
        zone_id = "\${data.cloudflare_zone.${zoneKey r.domain}.id}";
        name = if r.name == "" then "@" else r.name;
        inherit (r) type content;
        ttl = r.ttl or 600;
      });
    });
}
