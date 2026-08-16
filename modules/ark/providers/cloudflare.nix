{ lib, config, ... }:
let
  zoneKey = d: lib.replaceStrings [ "." ] [ "_" ] d;
in
{
  ark.dns.providers.cloudflare = {
    static = {
      terraform.required_providers.cloudflare = {
        source = "cloudflare/cloudflare";
        version = "~> 5.22.0";
      };
      provider.cloudflare = { };

      data.cloudflare_zone = builtins.listToAttrs (
        map (d: {
          name = zoneKey d.domain;
          value.filter.name = d.domain;
        }) (builtins.filter (d: d.provider == "cloudflare") config.ark.domains)
      );
    };

    records =
      { recordAttrs, lib, ... }:
      {
        resource.cloudflare_dns_record = recordAttrs (r: {
          zone_id = "\${data.cloudflare_zone.${zoneKey r.domain}.id}";
          name = if r.name == "" then "@" else r.name;
          inherit (r) type content;
          ttl = r.ttl or 600;
        });
      };
  };
}
